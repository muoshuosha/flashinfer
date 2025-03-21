/*
 * Copyright (c) 2024 by FlashInfer team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#ifndef FLASHINFER_SAMPLING_CUH_
#define FLASHINFER_SAMPLING_CUH_

#include <curand.h>
#include <curand_kernel.h>
#include <curand_philox4x32_x.h>

#include <cub/block/block_adjacent_difference.cuh>
#include <cub/block/block_reduce.cuh>
#include <cub/block/block_scan.cuh>
#include <cuda/std/limits>
#include <numeric>

#include "math.cuh"
#include "utils.cuh"
#include "vec_dtypes.cuh"

namespace flashinfer {

namespace sampling {

using namespace cub;

#define DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, ...) \
  if (deterministic) {                                            \
    constexpr bool DETERMINISTIC = true;                          \
    __VA_ARGS__                                                   \
  } else {                                                        \
    constexpr bool DETERMINISTIC = false;                         \
    __VA_ARGS__                                                   \
  }

#define DISPATCH_COMPUTE_CAP_NUM_THREADS(compute_capacity, BLOCK_THREADS, ...) \
  if (compute_capacity.first >= 8) {                                           \
    constexpr uint32_t BLOCK_THREADS = 1024;                                   \
    __VA_ARGS__                                                                \
  } else {                                                                     \
    constexpr uint32_t BLOCK_THREADS = 512;                                    \
    __VA_ARGS__                                                                \
  }

constexpr BlockScanAlgorithm SCAN_ALGO = BLOCK_SCAN_WARP_SCANS;
constexpr BlockReduceAlgorithm REDUCE_ALGO = BLOCK_REDUCE_WARP_REDUCTIONS;

#if (__CUDACC_VER_MAJOR__ * 10000 + __CUDACC_VER_MINOR__ * 100 >= 120100)
#define FLASHINFER_CUB_SUBTRACTLEFT_DEFINED
#endif

template <typename T>
struct Pair {
  T value;
  int count;

  __device__ Pair operator+(const Pair& other) const {
    return {value + other.value, count + other.count};
  }
  __device__ Pair& operator+=(const Pair& other) {
    value += other.value;
    count += other.count;
    return *this;
  }
};

struct BoolDiffOp {
  __device__ __forceinline__ bool operator()(const bool& lhs, const bool& rhs) const {
    return lhs != rhs;
  }
};

template <typename T, uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM>
struct SamplingTempStorage {
  union {
    T deterministic_scan[BLOCK_THREADS / 32];
    typename BlockScan<T, BLOCK_THREADS, SCAN_ALGORITHM>::TempStorage scan;
    typename BlockReduce<T, BLOCK_THREADS, REDUCE_ALGORITHM>::TempStorage reduce;
    typename BlockReduce<Pair<T>, BLOCK_THREADS, REDUCE_ALGORITHM>::TempStorage reduce_pair;
    typename BlockAdjacentDifference<bool, BLOCK_THREADS>::TempStorage adj_diff;
  } block_prim;
  struct {
    int32_t sampled_id;
    union {
      T value;
      Pair<T> pair;
      T max_p;
    } block_aggregate;
  };
};

/*!
 * \brief Deterministic inclusive scan implementation, use Belloch scan algorithm.
 * \note This implementation is slower than the cub::BlockScan, but it is deterministic.
 */
template <uint32_t VEC_SIZE, uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM, typename T>
__device__ __forceinline__ void DeterministicInclusiveSum(
    const T* in_data, T* out_data,
    SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>* temp_storage) {
  T* smem_prefix_sum = temp_storage->block_prim.deterministic_scan;
  T thread_data[VEC_SIZE];
  T thread_sum = 0;
#pragma unroll
  for (uint32_t i = 0; i < VEC_SIZE; ++i) {
    thread_sum += in_data[i];
    thread_data[i] = thread_sum;
  }

  T thread_exclusive_prefix_sum = thread_sum;

#pragma unroll
  for (uint32_t offset = 1; offset < 32; offset *= 2) {
    T tmp = __shfl_up_sync(0xffffffff, thread_exclusive_prefix_sum, offset);
    if ((threadIdx.x + 1) % (offset * 2) == 0) {
      thread_exclusive_prefix_sum += tmp;
    }
  }

  T warp_sum = __shfl_sync(0xffffffff, thread_exclusive_prefix_sum, threadIdx.x | 0xffffffff);
  if (threadIdx.x % 32 == 31) {
    thread_exclusive_prefix_sum = 0;
  }

#pragma unroll
  for (uint32_t offset = 16; offset >= 1; offset /= 2) {
    T tmp = __shfl_xor_sync(0xffffffff, thread_exclusive_prefix_sum, offset);
    if ((threadIdx.x + 1) % (offset * 2) == 0) {
      thread_exclusive_prefix_sum = tmp + thread_exclusive_prefix_sum;
    }
    if ((threadIdx.x + 1) % (offset * 2) == offset) {
      thread_exclusive_prefix_sum = tmp;
    }
  }

  smem_prefix_sum[threadIdx.x / 32] = warp_sum;
  __syncthreads();

  if (threadIdx.x < 32) {
    T warp_exclusive_prefix_sum =
        (threadIdx.x < BLOCK_THREADS / 32) ? smem_prefix_sum[threadIdx.x] : 0;

#pragma unroll
    for (uint32_t offset = 1; offset < 32; offset *= 2) {
      T tmp = __shfl_up_sync(0xffffffff, warp_exclusive_prefix_sum, offset);
      if ((threadIdx.x + 1) % (offset * 2) == 0) {
        warp_exclusive_prefix_sum += tmp;
      }
    }

    if (threadIdx.x % 32 == 31) {
      warp_exclusive_prefix_sum = 0;
    }

#pragma unroll
    for (uint32_t offset = 16; offset >= 1; offset /= 2) {
      T tmp = __shfl_xor_sync(0xffffffff, warp_exclusive_prefix_sum, offset);
      if ((threadIdx.x + 1) % (offset * 2) == 0) {
        warp_exclusive_prefix_sum = tmp + warp_exclusive_prefix_sum;
      }
      if ((threadIdx.x + 1) % (offset * 2) == offset) {
        warp_exclusive_prefix_sum = tmp;
      }
    }
    if (threadIdx.x < BLOCK_THREADS / 32) {
      smem_prefix_sum[threadIdx.x] = warp_exclusive_prefix_sum;
    }
  }
  __syncthreads();

#pragma unroll
  for (uint32_t i = 0; i < VEC_SIZE; ++i) {
    out_data[i] = smem_prefix_sum[threadIdx.x / 32] + thread_exclusive_prefix_sum + thread_data[i];
  }
}

template <uint32_t VEC_SIZE, uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM, bool DETERMINISTIC, typename T, typename Predicate>
__device__ __forceinline__ void DeviceSamplingFromProb(
    uint32_t i, uint32_t d, Predicate pred, T u, vec_t<T, VEC_SIZE> prob_vec, T& aggregate,
    SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>* temp_storage) {
  const uint32_t tx = threadIdx.x;
  T prob_greater_than_threshold[VEC_SIZE];
  T inclusive_cdf[VEC_SIZE];
  bool greater_than_u[VEC_SIZE], valid[VEC_SIZE];
#pragma unroll
  for (uint32_t j = 0; j < VEC_SIZE; ++j) {
    prob_greater_than_threshold[j] = pred(prob_vec[j]) ? prob_vec[j] : T(0);
    valid[j] = pred(prob_vec[j]) && (i * BLOCK_THREADS + tx) * VEC_SIZE < d;
  }
  T aggregate_local =
      BlockReduce<T, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage->block_prim.reduce)
          .Sum<VEC_SIZE>(prob_greater_than_threshold);
  if (tx == 0) {
    temp_storage->block_aggregate.value = aggregate_local;
  }
  __syncthreads();
  aggregate_local = temp_storage->block_aggregate.value;

  if (aggregate + aggregate_local > u) {
    if constexpr (DETERMINISTIC) {
      DeterministicInclusiveSum<VEC_SIZE, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM, T>(
          prob_greater_than_threshold, inclusive_cdf, temp_storage);
    } else {
      BlockScan<T, BLOCK_THREADS, SCAN_ALGORITHM>(temp_storage->block_prim.scan)
          .InclusiveSum<VEC_SIZE>(prob_greater_than_threshold, inclusive_cdf);

      __syncthreads();
    }

#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      greater_than_u[j] = (inclusive_cdf[j] + aggregate > u) && valid[j];
    }

    bool greater_than_u_diff[VEC_SIZE];
#ifdef FLASHINFER_CUB_SUBTRACTLEFT_DEFINED
    BlockAdjacentDifference<bool, BLOCK_THREADS>(temp_storage->block_prim.adj_diff)
        .SubtractLeft<VEC_SIZE>(greater_than_u, greater_than_u_diff, BoolDiffOp());
#else
    BlockAdjacentDifference<bool, BLOCK_THREADS>(temp_storage->block_prim.adj_diff)
        .FlagHeads<VEC_SIZE>(greater_than_u_diff, greater_than_u, BoolDiffOp(), 0);
#endif
    __syncthreads();

#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      if (greater_than_u_diff[j]) {
        atomicMin(&(temp_storage->sampled_id), (i * BLOCK_THREADS + tx) * VEC_SIZE + j);
      }
    }
    __syncthreads();
  }
  aggregate += aggregate_local;
}

template <uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE, bool DETERMINISTIC,
          typename DType, typename IdType>
__global__ void SamplingFromProbKernel(DType* probs, IdType* output, IdType* row_indices,
                                       uint32_t d, uint64_t philox_seed, uint64_t philox_offset) {
  curandStatePhilox4_32_10_t state;
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  curand_init(philox_seed, bx, philox_offset, &state);
  const uint32_t row_idx = row_indices == nullptr ? bx : row_indices[bx];

  extern __shared__ __align__(
      alignof(SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>))
      uint8_t smem_sampling[];
  auto& temp_storage = reinterpret_cast<
      SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>&>(smem_sampling);
  temp_storage.sampled_id = d - 1;
  __syncthreads();

  vec_t<DType, VEC_SIZE> probs_vec;
  DType aggregate(0);
  float u = curand_uniform(&state);

  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    probs_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.load(probs + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
    }

    DeviceSamplingFromProb<VEC_SIZE, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM, DETERMINISTIC,
                           DType>(
        i, d, [](DType x) { return x > 0; }, u, probs_vec, aggregate, &temp_storage);
    if (float(aggregate) > u) {
      break;
    }
  }
  output[bx] = temp_storage.sampled_id;
}

template <uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE, bool DETERMINISTIC,
          typename DType, typename IdType>
__global__ void TopKSamplingFromProbKernel(DType* probs, IdType* output, IdType* top_k_arr,
                                           uint32_t top_k_val, uint32_t d, uint64_t philox_seed,
                                           uint64_t philox_offset) {
  const uint32_t batch_size = gridDim.x;
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  curandStatePhilox4_32_10_t state;
  curand_init(philox_seed, bx, philox_offset, &state);
  uint32_t k = top_k_arr == nullptr ? top_k_val : top_k_arr[bx];

  extern __shared__ __align__(
      alignof(SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>))
      uint8_t smem_sampling[];
  auto& temp_storage = reinterpret_cast<
      SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>&>(smem_sampling);

  vec_t<DType, VEC_SIZE> probs_vec;
  float aggregate;
  float q = 1;
  double low = 0, high = 1;
  IdType sampled_id;
  do {
    temp_storage.sampled_id = d - 1;
    __syncthreads();
    float u = curand_uniform(&state) * q;
    aggregate = DType(0);
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      probs_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        probs_vec.load(probs + bx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
      }

      DeviceSamplingFromProb<VEC_SIZE, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM,
                             DETERMINISTIC, DType>(
          i, d, [&](DType x) { return x > low; }, u, probs_vec, aggregate, &temp_storage);
      if (aggregate > u) {
        break;
      }
    }
    __syncthreads();
    sampled_id = temp_storage.sampled_id;
    double pivot_0 = probs[bx * d + sampled_id];
    double pivot_1 = (pivot_0 + high) / 2;

    Pair<DType> aggregate_gt_pivot_0{DType(0), 0}, aggregate_gt_pivot_1{DType(0), 0};
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      probs_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        probs_vec.load(probs + bx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
      }

      Pair<DType> probs_gt_pivot_0[VEC_SIZE], probs_gt_pivot_1[VEC_SIZE];
#pragma unroll
      for (uint32_t j = 0; j < VEC_SIZE; ++j) {
        probs_gt_pivot_0[j] = {
            (probs_vec[j] > pivot_0) ? probs_vec[j] : DType(0),
            (probs_vec[j] > pivot_0 && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d)};
        probs_gt_pivot_1[j] = {
            (probs_vec[j] > pivot_1) ? probs_vec[j] : DType(0),
            (probs_vec[j] > pivot_1 && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d)};
      }

      aggregate_gt_pivot_0 += BlockReduce<Pair<DType>, BLOCK_THREADS, REDUCE_ALGORITHM>(
                                  temp_storage.block_prim.reduce_pair)
                                  .Sum<VEC_SIZE>(probs_gt_pivot_0);
      if (tx == 0) {
        temp_storage.block_aggregate.pair = aggregate_gt_pivot_0;
      }
      __syncthreads();
      aggregate_gt_pivot_0 = temp_storage.block_aggregate.pair;

      aggregate_gt_pivot_1 += BlockReduce<Pair<DType>, BLOCK_THREADS, REDUCE_ALGORITHM>(
                                  temp_storage.block_prim.reduce_pair)
                                  .Sum<VEC_SIZE>(probs_gt_pivot_1);
      if (tx == 0) {
        temp_storage.block_aggregate.pair = aggregate_gt_pivot_1;
      }
      __syncthreads();
      aggregate_gt_pivot_1 = temp_storage.block_aggregate.pair;
    }
    if (aggregate_gt_pivot_0.count < k) {
      // case 1: pivot_0 accepted
      break;
    }
    if (aggregate_gt_pivot_1.count < k) {
      // case 2: pivot_0 rejected, pivot_1 accepted
      low = pivot_0;
      high = pivot_1;
      q = aggregate_gt_pivot_0.value;
    } else {
      // case 3: pivot_0 rejected, pivot_1 rejected
      low = pivot_1;
      q = aggregate_gt_pivot_1.value;
    }
  } while (low < high);
  __syncthreads();
  if (tx == 0) {
    output[bx] = sampled_id;
  }
}

template <uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE, bool DETERMINISTIC,
          typename DType, typename IdType>
__global__ void TopPSamplingFromProbKernel(DType* probs, IdType* output, IdType* row_indices,
                                           float* top_p_arr, float top_p_val, uint32_t d,
                                           uint64_t philox_seed, uint64_t philox_offset) {
  const uint32_t batch_size = gridDim.x;
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  curandStatePhilox4_32_10_t state;
  curand_init(philox_seed, bx, philox_offset, &state);
  float top_p = (top_p_arr == nullptr) ? top_p_val : top_p_arr[bx];

  const uint32_t row_idx = row_indices == nullptr ? bx : row_indices[bx];

  extern __shared__ __align__(
      alignof(SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>))
      uint8_t smem_sampling[];
  auto& temp_storage = reinterpret_cast<
      SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>&>(smem_sampling);

  vec_t<DType, VEC_SIZE> probs_vec;
  DType aggregate;
  DType q = DType(1);
  double low = 0, high = 1;
  IdType sampled_id;
  do {
    temp_storage.sampled_id = d - 1;
    __syncthreads();
    DType u = curand_uniform(&state) * q;
    aggregate = DType(0);
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      probs_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        probs_vec.load(probs + row_idx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
      }

      DeviceSamplingFromProb<VEC_SIZE, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM,
                             DETERMINISTIC, DType>(
          i, d, [&](DType x) { return x > low; }, u, probs_vec, aggregate, &temp_storage);
      if (aggregate > u) {
        break;
      }
    }
    __syncthreads();
    sampled_id = temp_storage.sampled_id;
    double pivot_0 = probs[row_idx * d + sampled_id];
    double pivot_1 = (pivot_0 + high) / 2;

    float aggregate_gt_pivot_0 = 0, aggregate_gt_pivot_1 = 0;
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      probs_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        probs_vec.load(probs + row_idx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
      }

      DType probs_gt_pivot_0[VEC_SIZE], probs_gt_pivot_1[VEC_SIZE];
#pragma unroll
      for (uint32_t j = 0; j < VEC_SIZE; ++j) {
        probs_gt_pivot_0[j] = (probs_vec[j] > pivot_0) ? probs_vec[j] : DType(0);
        probs_gt_pivot_1[j] = (probs_vec[j] > pivot_1) ? probs_vec[j] : DType(0);
      }

      aggregate_gt_pivot_0 += BlockReduce<DType, BLOCK_THREADS>(temp_storage.block_prim.reduce)
                                  .Sum<VEC_SIZE>(probs_gt_pivot_0);
      if (tx == 0) {
        temp_storage.block_aggregate.value = aggregate_gt_pivot_0;
      }
      __syncthreads();
      aggregate_gt_pivot_0 = temp_storage.block_aggregate.value;

      aggregate_gt_pivot_1 += BlockReduce<DType, BLOCK_THREADS>(temp_storage.block_prim.reduce)
                                  .Sum<VEC_SIZE>(probs_gt_pivot_1);
      if (tx == 0) {
        temp_storage.block_aggregate.value = aggregate_gt_pivot_1;
      }
      __syncthreads();
      aggregate_gt_pivot_1 = temp_storage.block_aggregate.value;
    }
    if (aggregate_gt_pivot_0 < top_p) {
      // case 1: pivot_0 accepted
      break;
    }
    if (aggregate_gt_pivot_1 < top_p) {
      // case 2: pivot_0 rejected, pivot_1 accepted
      low = pivot_0;
      high = pivot_1;
      q = aggregate_gt_pivot_0;
    } else {
      // case 3: pivot_0 rejected, pivot_1 rejected
      low = pivot_1;
      q = aggregate_gt_pivot_1;
    }
  } while (low < high);
  __syncthreads();
  if (tx == 0) {
    output[bx] = sampled_id;
  }
}

template <uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE, bool DETERMINISTIC,
          typename DType, typename IdType>
__global__ void MinPSamplingFromProbKernel(DType* probs, DType* min_p_arr, IdType* output,
                                           float min_p_val, uint32_t d, uint64_t philox_seed,
                                           uint64_t philox_offset) {
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  DType p = (min_p_arr == nullptr) ? min_p_val : min_p_arr[bx];
  curandStatePhilox4_32_10_t state;
  curand_init(philox_seed, bx, philox_offset, &state);

  extern __shared__ __align__(
      alignof(SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>))
      uint8_t smem_sampling[];
  auto& temp_storage = reinterpret_cast<
      SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>&>(smem_sampling);

  vec_t<DType, VEC_SIZE> probs_vec;

  DType max_p = 0;
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    probs_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.load(probs + bx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
    }
    DType probs_[VEC_SIZE];
#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      probs_[j] = probs_vec[j];
    }
    max_p = max(max_p, BlockReduce<DType, BLOCK_THREADS>(temp_storage.block_prim.reduce)
                           .Reduce<VEC_SIZE>(probs_, cub::Max()));
    __syncthreads();
  }
  if (tx == 0) {
    temp_storage.block_aggregate.max_p = max_p;
  }
  __syncthreads();
  DType pivot = temp_storage.block_aggregate.max_p * p;

  DType aggregate_gt_pivot = DType(0);
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    probs_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.load(probs + bx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
    }

    DType probs_gt_pivot[VEC_SIZE];
#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      probs_gt_pivot[j] = (probs_vec[j] >= pivot) ? probs_vec[j] : DType(0);
    }

    aggregate_gt_pivot += BlockReduce<DType, BLOCK_THREADS>(temp_storage.block_prim.reduce)
                              .Sum<VEC_SIZE>(probs_gt_pivot);
    if (tx == 0) {
      temp_storage.block_aggregate.value = aggregate_gt_pivot;
    }
    __syncthreads();
  }

  DType aggregate(0);
  DType q = temp_storage.block_aggregate.value;

  IdType sampled_id;
  temp_storage.sampled_id = d - 1;
  __syncthreads();
  DType u = curand_uniform(&state) * q;
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    probs_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.load(probs + bx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
    }

    DeviceSamplingFromProb<VEC_SIZE, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM, DETERMINISTIC,
                           DType>(
        i, d, [&](DType x) { return x >= pivot; }, u, probs_vec, aggregate, &temp_storage);
    if (aggregate > u) {
      break;
    }
  }
  output[bx] = temp_storage.sampled_id;
}

template <uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE, bool DETERMINISTIC,
          typename DType, typename IdType>
__global__ void TopKTopPSamplingFromProbKernel(DType* probs, IdType* top_k_arr, DType* top_p_arr,
                                               IdType* output, IdType top_k_val, DType top_p_val,
                                               uint32_t d, uint64_t philox_seed,
                                               uint64_t philox_offset) {
  const uint32_t batch_size = gridDim.x;
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  curandStatePhilox4_32_10_t state;
  curand_init(philox_seed, bx, philox_offset, &state);
  IdType k = top_k_arr == nullptr ? top_k_val : top_k_arr[bx];
  DType p = top_p_arr == nullptr ? top_p_val : top_p_arr[bx];

  extern __shared__ __align__(
      alignof(SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>))
      uint8_t smem_sampling[];
  auto& temp_storage = reinterpret_cast<
      SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>&>(smem_sampling);

  vec_t<DType, VEC_SIZE> probs_vec;
  float aggregate;
  float q = 1;
  double low = 0, high = 1;
  IdType sampled_id;
  do {
    temp_storage.sampled_id = d - 1;
    __syncthreads();
    float u = curand_uniform(&state) * q;
    aggregate = 0;
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      probs_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        probs_vec.load(probs + bx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
      }

      DeviceSamplingFromProb<VEC_SIZE, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM,
                             DETERMINISTIC, DType>(
          i, d, [&](DType x) { return x > low; }, u, probs_vec, aggregate, &temp_storage);
      if (aggregate > u) {
        break;
      }
    }
    __syncthreads();
    sampled_id = temp_storage.sampled_id;
    double pivot_0 = probs[bx * d + sampled_id];
    double pivot_1 = (pivot_0 + high) / 2;

    Pair<DType> aggregate_gt_pivot_0{DType(0), 0}, aggregate_gt_pivot_1{DType(0), 0};
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      probs_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        probs_vec.load(probs + bx * d + (i * BLOCK_THREADS + tx) * VEC_SIZE);
      }

      Pair<DType> probs_gt_pivot_0[VEC_SIZE], probs_gt_pivot_1[VEC_SIZE];
#pragma unroll
      for (uint32_t j = 0; j < VEC_SIZE; ++j) {
        probs_gt_pivot_0[j] = {
            (probs_vec[j] > pivot_0) ? probs_vec[j] : DType(0),
            (probs_vec[j] > pivot_0 && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d)};
        probs_gt_pivot_1[j] = {
            (probs_vec[j] > pivot_1) ? probs_vec[j] : DType(0),
            (probs_vec[j] > pivot_1 && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d)};
      }

      aggregate_gt_pivot_0 +=
          BlockReduce<Pair<DType>, BLOCK_THREADS>(temp_storage.block_prim.reduce_pair)
              .Sum<VEC_SIZE>(probs_gt_pivot_0);
      if (tx == 0) {
        temp_storage.block_aggregate.pair = aggregate_gt_pivot_0;
      }
      __syncthreads();
      aggregate_gt_pivot_0 = temp_storage.block_aggregate.pair;

      aggregate_gt_pivot_1 +=
          BlockReduce<Pair<DType>, BLOCK_THREADS>(temp_storage.block_prim.reduce_pair)
              .Sum<VEC_SIZE>(probs_gt_pivot_1);
      if (tx == 0) {
        temp_storage.block_aggregate.pair = aggregate_gt_pivot_1;
      }
      __syncthreads();
      aggregate_gt_pivot_1 = temp_storage.block_aggregate.pair;
    }
    if (aggregate_gt_pivot_0.count < k && aggregate_gt_pivot_0.value < p) {
      // case 1: pivot_0 accepted
      break;
    }
    if (aggregate_gt_pivot_1.count < k && aggregate_gt_pivot_1.value < p) {
      // case 2: pivot_0 rejected, pivot_1 accepted
      low = pivot_0;
      high = pivot_1;
      q = aggregate_gt_pivot_0.value;
    } else {
      // case 3: pivot_0 rejected, pivot_1 rejected
      low = pivot_1;
      q = aggregate_gt_pivot_1.value;
    }
  } while (low < high);
  __syncthreads();
  if (tx == 0) {
    output[bx] = sampled_id;
  }
}

template <typename T, typename IdType>
cudaError_t SamplingFromProb(T* probs, IdType* output, uint32_t batch_size, uint32_t d,
                             bool deterministic, uint64_t philox_seed, uint64_t philox_offset,
                             cudaStream_t stream = 0) {
  constexpr uint32_t BLOCK_THREADS = 1024;
  const uint32_t vec_size = std::gcd(16 / sizeof(T), d);
  dim3 nblks(batch_size);
  dim3 nthrs(BLOCK_THREADS);
  IdType* row_indices_placeholder = nullptr;
  void* args[] = {&probs, &output, &row_indices_placeholder, &d, &philox_seed, &philox_offset, &d};
  const uint32_t smem_size = sizeof(SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO>);

  DISPATCH_ALIGNED_VEC_SIZE(
      vec_size, VEC_SIZE, {DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, {
        auto kernel = SamplingFromProbKernel<BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO, VEC_SIZE,
                                             DETERMINISTIC, T, IdType>;
        FLASHINFER_CUDA_CALL(
            cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
      })});
  return cudaSuccess;
}

template <typename T, typename IdType>
cudaError_t ParallelSamplingFromProb(T* probs, IdType* output, IdType* row_indices,
                                     uint32_t batch_size, uint32_t d, bool deterministic,
                                     uint64_t philox_seed, uint64_t philox_offset,
                                     cudaStream_t stream = 0) {
  constexpr uint32_t BLOCK_THREADS = 1024;
  const uint32_t vec_size = std::gcd(16 / sizeof(T), d);
  dim3 nblks(batch_size);
  dim3 nthrs(BLOCK_THREADS);
  void* args[] = {&probs, &output, &row_indices, &philox_seed, &philox_offset, &d};
  const uint32_t smem_size = sizeof(SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO>);

  DISPATCH_ALIGNED_VEC_SIZE(
      vec_size, VEC_SIZE, {DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, {
        auto kernel = SamplingFromProbKernel<BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO, VEC_SIZE,
                                             DETERMINISTIC, T, IdType>;
        FLASHINFER_CUDA_CALL(
            cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
      })});
  return cudaSuccess;
}

template <typename T, typename IdType>
cudaError_t TopKSamplingFromProb(T* probs, IdType* output, T* top_k_arr, uint32_t batch_size,
                                 uint32_t top_k_val, uint32_t d, bool deterministic,
                                 uint64_t philox_seed, uint64_t philox_offset,
                                 cudaStream_t stream = 0) {
  const uint32_t vec_size = std::gcd(16 / sizeof(T), d);

  auto compute_capacity = GetCudaComputeCapability();
  DISPATCH_COMPUTE_CAP_NUM_THREADS(compute_capacity, BLOCK_THREADS, {
    const uint32_t smem_size =
        sizeof(SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO>);
    dim3 nblks(batch_size);
    dim3 nthrs(BLOCK_THREADS);
    void* args[] = {&probs, &output, &top_k_arr, &top_k_val, &d, &philox_seed, &philox_offset};

    DISPATCH_ALIGNED_VEC_SIZE(
        vec_size, VEC_SIZE, {DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, {
          auto kernel = TopKSamplingFromProbKernel<BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO, VEC_SIZE,
                                                   DETERMINISTIC, T, IdType>;
          FLASHINFER_CUDA_CALL(
              cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
          FLASHINFER_CUDA_CALL(
              cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
        })});
    return cudaSuccess;
  });
}

template <typename T, typename IdType>
cudaError_t TopPSamplingFromProb(T* probs, IdType* output, T* top_p_arr, uint32_t batch_size,
                                 T top_p_val, uint32_t d, bool deterministic, uint64_t philox_seed,
                                 uint64_t philox_offset, cudaStream_t stream = 0) {
  constexpr uint32_t BLOCK_THREADS = 1024;
  const uint32_t vec_size = std::gcd(16 / sizeof(T), d);

  const uint32_t smem_size = sizeof(SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO>);
  dim3 nblks(batch_size);
  dim3 nthrs(BLOCK_THREADS);
  IdType* row_indices_placeholder = nullptr;
  void* args[] = {&probs,       &output,       &row_indices_placeholder, &top_p_arr, &top_p_val, &d,
                  &philox_seed, &philox_offset};

  DISPATCH_ALIGNED_VEC_SIZE(
      vec_size, VEC_SIZE, {DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, {
        auto kernel = TopPSamplingFromProbKernel<BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO, VEC_SIZE,
                                                 DETERMINISTIC, T, IdType>;
        FLASHINFER_CUDA_CALL(
            cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
        FLASHINFER_CUDA_CALL(
            cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
      })});
  return cudaSuccess;
}

template <typename T, typename IdType>
cudaError_t MinPSamplingFromProb(T* probs, T* min_p_arr, IdType* output, uint32_t batch_size,
                                 float min_p_val, uint32_t d, bool deterministic,
                                 uint64_t philox_seed, uint64_t philox_offset,
                                 cudaStream_t stream = 0) {
  constexpr uint32_t BLOCK_THREADS = 1024;
  const uint32_t vec_size = std::gcd(16 / sizeof(T), d);

  const uint32_t smem_size = sizeof(SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO>);
  dim3 nblks(batch_size);
  dim3 nthrs(BLOCK_THREADS);
  void* args[] = {&probs, &min_p_arr, &output, &min_p_val, &d, &philox_seed, &philox_offset};

  DISPATCH_ALIGNED_VEC_SIZE(
      vec_size, VEC_SIZE, {DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, {
        auto kernel = MinPSamplingFromProbKernel<BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO, VEC_SIZE,
                                                 DETERMINISTIC, T, IdType>;
        FLASHINFER_CUDA_CALL(
            cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
        FLASHINFER_CUDA_CALL(
            cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
      })});
  return cudaSuccess;
}

template <typename T, typename IdType>
cudaError_t TopKTopPSamplingFromProb(T* probs, IdType* top_k_arr, T* top_p_arr, IdType* output,
                                     uint32_t batch_size, IdType top_k_val, T top_p_val, uint32_t d,
                                     bool deterministic, uint64_t philox_seed,
                                     uint64_t philox_offset, cudaStream_t stream = 0) {
  const uint32_t vec_size = std::gcd(16 / sizeof(T), d);

  auto compute_capacity = GetCudaComputeCapability();
  DISPATCH_COMPUTE_CAP_NUM_THREADS(compute_capacity, BLOCK_THREADS, {
    const uint32_t smem_size =
        sizeof(SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO>);
    dim3 nblks(batch_size);
    dim3 nthrs(BLOCK_THREADS);
    void* args[] = {&probs,     &top_k_arr, &top_p_arr,   &output,       &top_k_val,
                    &top_p_val, &d,         &philox_seed, &philox_offset};

    DISPATCH_ALIGNED_VEC_SIZE(
        vec_size, VEC_SIZE, {DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, {
          auto kernel = TopKTopPSamplingFromProbKernel<BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO,
                                                       VEC_SIZE, DETERMINISTIC, T, IdType>;
          FLASHINFER_CUDA_CALL(
              cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
          FLASHINFER_CUDA_CALL(
              cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
        })});
    return cudaSuccess;
  });
}

template <typename T, uint32_t BLOCK_THREADS, BlockReduceAlgorithm REDUCE_ALGORITHM>
struct RenormTempStorage {
  union {
    typename BlockReduce<T, BLOCK_THREADS, REDUCE_ALGORITHM>::TempStorage reduce;
    typename BlockReduce<int, BLOCK_THREADS, REDUCE_ALGORITHM>::TempStorage reduce_int;
    typename BlockReduce<Pair<T>, BLOCK_THREADS, REDUCE_ALGORITHM>::TempStorage reduce_pair;
  } block_prim;
  struct {
    T max_val;
    T min_val;
    union {
      T value;
      int count;
      Pair<T> pair;
    } block_aggregate;
  };
};

template <uint32_t BLOCK_THREADS, BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE,
          typename DType>
__global__ void TopPRenormProbKernel(DType* probs, DType* renormed_prob, DType* top_p_arr,
                                     float top_p_val, uint32_t d) {
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  const uint32_t row_idx = bx;
  float p = top_p_arr == nullptr ? top_p_val : top_p_arr[bx];

  extern __shared__ __align__(alignof(RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>))
      uint8_t smem_renorm[];
  auto& temp_storage =
      reinterpret_cast<RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>&>(smem_renorm);
  temp_storage.max_val = DType(0);
  vec_t<DType, VEC_SIZE> probs_vec;
  DType probs_greater_than_pivot[VEC_SIZE];  // pivot initialized to 0

  DType threadlocal_max_val = DType(0);
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    probs_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.load(probs + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
    }
#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      probs_greater_than_pivot[j] = probs_vec[j];
    }
    threadlocal_max_val =
        max(threadlocal_max_val,
            BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
                .Reduce<VEC_SIZE>(probs_greater_than_pivot, cub::Max()));
    __syncthreads();
  }
  if (tx == 0) {
    temp_storage.max_val = threadlocal_max_val;
  }
  __syncthreads();
  threadlocal_max_val = temp_storage.max_val;

  double low = 0, high = threadlocal_max_val;
  DType min_gt_low, max_le_high;
  DType sum_low(1);
  // f(x) = sum(probs[probs > x]), f(x) is non-increasing
  // min_gt_low = min{p \in probs | p > low}, max_le_high = max{p \in probs | p <= high}
  // loop invariant:
  // - f(low) >= p, f(high) < p
  // - f(low) > f(min_gt_low) >= f(max_le_high) == f(high)
  // stopping condition
  // - f(low) >= p, f(min_gt_low) == f(max_le_high) == f(high) < p
  do {
    DType threadlocal_sum(0);
    double mid = (low + high) / 2;
    min_gt_low = high;
    max_le_high = low;
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      probs_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        probs_vec.load(probs + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
      }
#pragma unroll
      for (uint32_t j = 0; j < VEC_SIZE; ++j) {
        probs_greater_than_pivot[j] = (probs_vec[j] > mid) ? probs_vec[j] : DType(0);
        if (probs_vec[j] > low && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d) {
          min_gt_low = min(min_gt_low, probs_vec[j]);
        }
        if (probs_vec[j] <= high && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d) {
          max_le_high = max(max_le_high, probs_vec[j]);
        }
      }
      threadlocal_sum +=
          BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
              .Sum<VEC_SIZE>(probs_greater_than_pivot);
      __syncthreads();
    }
    min_gt_low = BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
                     .Reduce(min_gt_low, cub::Min());
    __syncthreads();
    max_le_high =
        BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
            .Reduce(max_le_high, cub::Max());
    if (tx == 0) {
      temp_storage.block_aggregate.value = threadlocal_sum;
      temp_storage.min_val = min_gt_low;
      temp_storage.max_val = max_le_high;
    }
    __syncthreads();
    threadlocal_sum = temp_storage.block_aggregate.value;
    min_gt_low = temp_storage.min_val;
    max_le_high = temp_storage.max_val;
    if (threadlocal_sum >= p) {
      low = mid;
      sum_low = float(threadlocal_sum);
    } else {
      high = min(mid, max_le_high);
    }
  } while (min_gt_low != max_le_high);

  DType normalizer = math::ptx_rcp(max(sum_low, 1e-8));

  // normalize
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    probs_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.load(probs + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
    }
#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      probs_vec[j] = (probs_vec[j] > low) ? probs_vec[j] * normalizer : DType(0);
    }
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.store(renormed_prob + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
    }
  }
}

template <uint32_t BLOCK_THREADS, BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE,
          typename DType, typename IdType>
__global__ void TopKMaskLogitsKernel(DType* logits, DType* masked_logits, IdType* top_k_arr,
                                     uint32_t top_k_val, uint32_t d) {
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  const uint32_t row_idx = bx;
  uint32_t k = top_k_arr == nullptr ? top_k_val : top_k_arr[bx];
  float pivot = -cuda::std::numeric_limits<float>::infinity();
  vec_t<DType, VEC_SIZE> logits_vec;
  if (k < d) {
    extern __shared__ __align__(alignof(RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>))
        uint8_t smem_renorm[];
    auto& temp_storage =
        reinterpret_cast<RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>&>(smem_renorm);
    DType logits_greater_than_pivot[VEC_SIZE];  // pivot initialized to 0

    DType threadlocal_max_val = DType(-cuda::std::numeric_limits<float>::infinity()),
          threadlocal_min_val = DType(cuda::std::numeric_limits<float>::infinity());
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      logits_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        logits_vec.load(logits + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
      }
#pragma unroll
      for (uint32_t j = 0; j < VEC_SIZE; ++j) {
        logits_greater_than_pivot[j] = logits_vec[j];
      }
      threadlocal_max_val =
          max(threadlocal_max_val,
              BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
                  .Reduce<VEC_SIZE>(logits_greater_than_pivot, cub::Max()));
      __syncthreads();
      threadlocal_min_val =
          min(threadlocal_min_val,
              BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
                  .Reduce<VEC_SIZE>(logits_greater_than_pivot, cub::Min()));
      __syncthreads();
    }
    if (tx == 0) {
      temp_storage.max_val = threadlocal_max_val;
      temp_storage.min_val = threadlocal_min_val;
    }
    __syncthreads();
    threadlocal_max_val = temp_storage.max_val;
    threadlocal_min_val = temp_storage.min_val;

    double low = threadlocal_min_val - 1, high = threadlocal_max_val;
    DType min_gt_low, max_le_high;
    // f(x) = len(nonzero(probs > x)), f(x) is non-increasing
    // min_gt_low = min{p \in probs | p > low}, max_le_high = max{p \in probs | p <= high}
    // loop invariant:
    // - f(low) >= k, f(high) < k
    // - f(low) > f(min_gt_low) >= f(max_le_high) == f(high)
    // stopping condition: min_gt_low == max_le_high
    // - f(low) >= k, f(min_gt_low) == f(max_le_high) == f(high) < k
    do {
      int threadlocal_count_sum = 0;
      int probs_greater_than_pivot_count[VEC_SIZE];  // pivot initialized to 0
      double mid = (low + high) / 2;
      min_gt_low = high;
      max_le_high = low;
      for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
        logits_vec.fill(DType(0));
        if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
          logits_vec.load(logits + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
        }
#pragma unroll
        for (uint32_t j = 0; j < VEC_SIZE; ++j) {
          probs_greater_than_pivot_count[j] =
              logits_vec[j] > mid && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d;
          if (logits_vec[j] > low && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d) {
            min_gt_low = min(min_gt_low, logits_vec[j]);
          }
          if (logits_vec[j] <= high && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d) {
            max_le_high = max(max_le_high, logits_vec[j]);
          }
        }
        threadlocal_count_sum +=
            BlockReduce<int, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce_int)
                .Sum<VEC_SIZE>(probs_greater_than_pivot_count);
        __syncthreads();
      }
      min_gt_low =
          BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
              .Reduce(min_gt_low, cub::Min());
      __syncthreads();
      max_le_high =
          BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
              .Reduce(max_le_high, cub::Max());
      if (tx == 0) {
        temp_storage.block_aggregate.count = threadlocal_count_sum;
        temp_storage.min_val = min_gt_low;
        temp_storage.max_val = max_le_high;
      }
      __syncthreads();
      threadlocal_count_sum = temp_storage.block_aggregate.count;
      min_gt_low = temp_storage.min_val;
      max_le_high = temp_storage.max_val;
      if (threadlocal_count_sum >= k) {
        low = mid;
      } else {
        high = min(mid, max_le_high);
      }
    } while (min_gt_low != max_le_high);
    pivot = low;
  }

  // masking
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    logits_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      logits_vec.load(logits + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
    }
#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      logits_vec[j] = (logits_vec[j] > pivot)
                          ? logits_vec[j]
                          : DType(-cuda::std::numeric_limits<float>::infinity());
    }
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      logits_vec.store(masked_logits + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
    }
  }
}

template <uint32_t BLOCK_THREADS, BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE,
          typename DType, typename IdType>
__global__ void TopKRenormProbKernel(DType* probs, DType* renormed_prob, IdType* top_k_arr,
                                     uint32_t top_k_val, uint32_t d) {
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  const uint32_t row_idx = bx;
  uint32_t k = top_k_arr == nullptr ? top_k_val : top_k_arr[bx];
  float pivot = -cuda::std::numeric_limits<float>::infinity(), normalizer = 1;
  vec_t<DType, VEC_SIZE> probs_vec;
  if (k < d) {
    extern __shared__ __align__(alignof(RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>))
        uint8_t smem_renorm[];
    auto& temp_storage =
        reinterpret_cast<RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>&>(smem_renorm);
    temp_storage.max_val = DType(0);
    DType probs_greater_than_pivot[VEC_SIZE];  // pivot initialized to 0

    DType threadlocal_max_val = DType(0);
    for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
      probs_vec.fill(DType(0));
      if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
        probs_vec.load(probs + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
      }
#pragma unroll
      for (uint32_t j = 0; j < VEC_SIZE; ++j) {
        probs_greater_than_pivot[j] = probs_vec[j];
      }
      threadlocal_max_val =
          max(threadlocal_max_val,
              BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
                  .Reduce<VEC_SIZE>(probs_greater_than_pivot, cub::Max()));
      __syncthreads();
    }
    if (tx == 0) {
      temp_storage.max_val = threadlocal_max_val;
    }
    __syncthreads();
    threadlocal_max_val = temp_storage.max_val;

    double low = 0, high = threadlocal_max_val;
    DType min_gt_low, max_le_high;
    DType sum_low(1);
    // f(x) = len(nonzero(probs > x)), f(x) is non-increasing
    // min_gt_low = min{p \in probs | p > low}, max_le_high = max{p \in probs | p <= high}
    // loop invariant:
    // - f(low) >= k, f(high) < k
    // - f(low) > f(min_gt_low) >= f(max_le_high) == f(high)
    // stopping condition: min_gt_low == max_le_high
    // - f(low) >= k, f(min_gt_low) == f(max_le_high) == f(high) < k
    do {
      Pair<DType> threadlocal_sum{DType(0), 0};
      Pair<DType> probs_greater_than_pivot_pair[VEC_SIZE];  // pivot initialized to 0
      double mid = (low + high) / 2;
      min_gt_low = high;
      max_le_high = low;
      for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
        probs_vec.fill(DType(0));
        if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
          probs_vec.load(probs + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
        }
#pragma unroll
        for (uint32_t j = 0; j < VEC_SIZE; ++j) {
          probs_greater_than_pivot_pair[j] = {
              (probs_vec[j] > mid) ? probs_vec[j] : DType(0),
              (probs_vec[j] > mid && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d)};
          if (probs_vec[j] > low && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d) {
            min_gt_low = min(min_gt_low, probs_vec[j]);
          }
          if (probs_vec[j] <= high && (i * BLOCK_THREADS + tx) * VEC_SIZE + j < d) {
            max_le_high = max(max_le_high, probs_vec[j]);
          }
        }
        threadlocal_sum += BlockReduce<Pair<DType>, BLOCK_THREADS, REDUCE_ALGORITHM>(
                               temp_storage.block_prim.reduce_pair)
                               .Sum<VEC_SIZE>(probs_greater_than_pivot_pair);
        __syncthreads();
      }
      min_gt_low =
          BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
              .Reduce(min_gt_low, cub::Min());
      __syncthreads();
      max_le_high =
          BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
              .Reduce(max_le_high, cub::Max());
      if (tx == 0) {
        temp_storage.block_aggregate.pair = threadlocal_sum;
        temp_storage.min_val = min_gt_low;
        temp_storage.max_val = max_le_high;
      }
      __syncthreads();
      threadlocal_sum = temp_storage.block_aggregate.pair;
      min_gt_low = temp_storage.min_val;
      max_le_high = temp_storage.max_val;
      if (threadlocal_sum.count >= k) {
        low = mid;
        sum_low = float(threadlocal_sum.value);
      } else {
        high = min(mid, max_le_high);
      }
    } while (min_gt_low != max_le_high);

    normalizer = math::ptx_rcp(max(sum_low, 1e-8));
    pivot = low;
  }

  // normalize
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    probs_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.load(probs + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
    }
#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      probs_vec[j] = (probs_vec[j] > pivot) ? probs_vec[j] * normalizer : DType(0);
    }
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      probs_vec.store(renormed_prob + row_idx * d + i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
    }
  }
}

template <typename DType>
cudaError_t TopPRenormProb(DType* probs, DType* renormed_prob, DType* top_p_arr,
                           uint32_t batch_size, float top_p_val, uint32_t d,
                           cudaStream_t stream = 0) {
  constexpr uint32_t BLOCK_THREADS = 1024;
  const uint32_t vec_size = std::gcd(16 / sizeof(DType), d);

  const uint32_t smem_size = sizeof(RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>);
  dim3 nblks(batch_size);
  dim3 nthrs(BLOCK_THREADS);
  void* args[] = {&probs, &renormed_prob, &top_p_arr, &top_p_val, &d};
  DISPATCH_ALIGNED_VEC_SIZE(vec_size, VEC_SIZE, {
    auto kernel = TopPRenormProbKernel<BLOCK_THREADS, REDUCE_ALGO, VEC_SIZE, DType>;
    FLASHINFER_CUDA_CALL(
        cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
    FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
  });
  return cudaSuccess;
}

template <typename DType, typename IdType>
cudaError_t TopKRenormProb(DType* probs, DType* renormed_prob, IdType* top_k_arr,
                           uint32_t batch_size, uint32_t top_k_val, uint32_t d,
                           cudaStream_t stream = 0) {
  const uint32_t vec_size = std::gcd(16 / sizeof(DType), d);

  auto compute_capacity = GetCudaComputeCapability();
  DISPATCH_COMPUTE_CAP_NUM_THREADS(compute_capacity, BLOCK_THREADS, {
    const uint32_t smem_size = sizeof(RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>);
    dim3 nblks(batch_size);
    dim3 nthrs(BLOCK_THREADS);
    void* args[] = {&probs, &renormed_prob, &top_k_arr, &top_k_val, &d};
    DISPATCH_ALIGNED_VEC_SIZE(vec_size, VEC_SIZE, {
      auto kernel = TopKRenormProbKernel<BLOCK_THREADS, REDUCE_ALGO, VEC_SIZE, DType, IdType>;
      FLASHINFER_CUDA_CALL(
          cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
      FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
    });
    return cudaSuccess;
  });
}

template <typename DType, typename IdType>
cudaError_t TopKMaskLogits(DType* logits, DType* masked_logits, IdType* top_k_arr,
                           uint32_t batch_size, uint32_t top_k_val, uint32_t d,
                           cudaStream_t stream = 0) {
  const uint32_t vec_size = std::gcd(16 / sizeof(DType), d);

  auto compute_capacity = GetCudaComputeCapability();
  DISPATCH_COMPUTE_CAP_NUM_THREADS(compute_capacity, BLOCK_THREADS, {
    const uint32_t smem_size = sizeof(RenormTempStorage<DType, BLOCK_THREADS, REDUCE_ALGO>);
    dim3 nblks(batch_size);
    dim3 nthrs(BLOCK_THREADS);
    void* args[] = {&logits, &masked_logits, &top_k_arr, &top_k_val, &d};
    DISPATCH_ALIGNED_VEC_SIZE(vec_size, VEC_SIZE, {
      auto kernel = TopKMaskLogitsKernel<BLOCK_THREADS, REDUCE_ALGO, VEC_SIZE, DType, IdType>;
      FLASHINFER_CUDA_CALL(
          cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
      FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
    });
    return cudaSuccess;
  });
}

template <uint32_t BLOCK_THREADS, BlockScanAlgorithm SCAN_ALGORITHM,
          BlockReduceAlgorithm REDUCE_ALGORITHM, uint32_t VEC_SIZE, bool DETERMINISTIC,
          typename DType, typename IdType>
__global__ void ChainSpeculativeSampling(DType* draft_probs, IdType* draft_token_ids,
                                         DType* target_probs, IdType* output_token_ids,
                                         IdType* output_accepted_token_num,
                                         IdType* output_emitted_token_num,
                                         uint32_t num_speculative_tokens, uint32_t d,
                                         uint64_t philox_seed, uint64_t philox_offset) {
  const uint32_t bx = blockIdx.x, tx = threadIdx.x;
  const uint32_t row_idx = bx;
  curandStatePhilox4_32_10_t curand_state;
  curand_init(philox_seed, bx, philox_offset, &curand_state);

  extern __shared__ __align__(
      alignof(SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>))
      uint8_t smem_sampling[];
  auto& temp_storage = reinterpret_cast<
      SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM>&>(smem_sampling);

  uint32_t pos = num_speculative_tokens;
  for (uint32_t i = 0; i < num_speculative_tokens; ++i) {
    IdType draft_id = draft_token_ids[row_idx * num_speculative_tokens + i];
    float q = target_probs[(row_idx * (num_speculative_tokens + 1) + i) * d + draft_id],
          p = draft_probs[(row_idx * num_speculative_tokens + i) * d + draft_id];
    DType u = curand_uniform(&curand_state);
    if (u * p < q) {
      // accept the draft models output
      output_token_ids[row_idx * (num_speculative_tokens + 1) + i] = draft_id;
    } else {
      pos = i;
      break;
    }
  }

  uint32_t emitted_token_num = pos;
  uint32_t accepted_token_num = pos;
  for (uint32_t i = pos; i < num_speculative_tokens; ++i) {
    IdType draft_id = draft_token_ids[row_idx * num_speculative_tokens + i];
    float q = target_probs[(row_idx * (num_speculative_tokens + 1) + i) * d + draft_id],
          p = draft_probs[(row_idx * num_speculative_tokens + i) * d + draft_id];
    DType u = curand_uniform(&curand_state);
    if (u * p < q) {
      ++accepted_token_num;
    }
  }

  if (tx == 0) {
    output_accepted_token_num[row_idx] += accepted_token_num;
    output_emitted_token_num[row_idx] += emitted_token_num;
  }

  // sample from relu(target_probs - draft_probs)
  DType sum_relu_q_minus_p(0);
  vec_t<DType, VEC_SIZE> q_vec, p_vec;
  DType relu_q_minus_p[VEC_SIZE];
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    q_vec.fill(DType(0));
    p_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      q_vec.load(target_probs + (row_idx * (num_speculative_tokens + 1) + pos) * d +
                 i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
      if (pos != num_speculative_tokens) {
        // there is no draft_probs for the bonus token
        p_vec.load(draft_probs + (row_idx * num_speculative_tokens + pos) * d +
                   i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
      }
    }
#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      relu_q_minus_p[j] = max(q_vec[j] - p_vec[j], DType(0));
    }
    sum_relu_q_minus_p +=
        BlockReduce<DType, BLOCK_THREADS, REDUCE_ALGORITHM>(temp_storage.block_prim.reduce)
            .Sum<VEC_SIZE>(relu_q_minus_p);
    __syncthreads();
  }
  if (tx == 0) {
    temp_storage.block_aggregate.value = sum_relu_q_minus_p;
  }
  // init the first rejected token to (d - 1)
  temp_storage.sampled_id = d - 1;
  __syncthreads();
  sum_relu_q_minus_p = temp_storage.block_aggregate.value;
  DType u = curand_uniform(&curand_state);
  u = u * sum_relu_q_minus_p;

  DType aggregate_relu_q_minus_p(0);
  for (uint32_t i = 0; i < ceil_div(d, BLOCK_THREADS * VEC_SIZE); ++i) {
    q_vec.fill(DType(0));
    p_vec.fill(DType(0));
    if ((i * BLOCK_THREADS + tx) * VEC_SIZE < d) {
      q_vec.load(target_probs + (row_idx * (num_speculative_tokens + 1) + pos) * d +
                 i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
      if (pos != num_speculative_tokens) {
        // there is no draft_probs for the bonus token
        p_vec.load(draft_probs + (row_idx * num_speculative_tokens + pos) * d +
                   i * BLOCK_THREADS * VEC_SIZE + tx * VEC_SIZE);
      }
    }

    vec_t<DType, VEC_SIZE> relu_q_minus_p_vec;
#pragma unroll
    for (uint32_t j = 0; j < VEC_SIZE; ++j) {
      relu_q_minus_p_vec[j] = max(q_vec[j] - p_vec[j], DType(0));
    }

    DeviceSamplingFromProb<VEC_SIZE, BLOCK_THREADS, SCAN_ALGORITHM, REDUCE_ALGORITHM, DETERMINISTIC,
                           DType>(
        i, d, [&](DType x) { return x > 0; }, u, relu_q_minus_p_vec, aggregate_relu_q_minus_p,
        &temp_storage);
    if (aggregate_relu_q_minus_p > u) {
      break;
    }
  }
  __syncthreads();
  // set the first rejected token
  output_token_ids[row_idx * (num_speculative_tokens + 1) + pos] = temp_storage.sampled_id;
  // move to the next token
  pos++;

  // pad remaining tokens with -1
  for (; pos < num_speculative_tokens + 1; ++pos) {
    output_token_ids[row_idx * (num_speculative_tokens + 1) + pos] = -1;
  }
}

template <typename T, typename IdType>
cudaError_t ParallelTopPSamplingFromProb(T* probs, IdType* output, IdType* row_indices,
                                         float* top_p_arr, uint32_t batch_size, float top_p_val,
                                         uint32_t d, bool deterministic, uint64_t philox_seed,
                                         uint64_t philox_offset, cudaStream_t stream = 0) {
  constexpr uint32_t BLOCK_THREADS = 1024;
  const uint32_t vec_size = std::gcd(16 / sizeof(T), d);

  const uint32_t smem_size = sizeof(SamplingTempStorage<T, BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO>);
  dim3 nblks(batch_size);
  dim3 nthrs(BLOCK_THREADS);
  void* args[] = {&probs,     &output, &row_indices, &top_p_arr,
                  &top_p_val, &d,      &philox_seed, &philox_offset};

  DISPATCH_ALIGNED_VEC_SIZE(
      vec_size, VEC_SIZE, {DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, {
        auto kernel = TopPSamplingFromProbKernel<BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO, VEC_SIZE,
                                                 DETERMINISTIC, T, IdType>;
        FLASHINFER_CUDA_CALL(
            cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
        FLASHINFER_CUDA_CALL(
            cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
      })});
  return cudaSuccess;
}

template <typename DType, typename IdType>
cudaError_t ChainSpeculativeSampling(DType* draft_probs, IdType* draft_token_ids,
                                     DType* target_probs, IdType* output_token_ids,
                                     IdType* output_accepted_token_num,
                                     IdType* output_emitted_token_num, uint32_t batch_size,
                                     uint32_t num_speculative_tokens, uint32_t d,
                                     bool deterministic, uint64_t philox_seed,
                                     uint64_t philox_offset, cudaStream_t stream = 0) {
  constexpr uint32_t BLOCK_THREADS = 1024;
  const uint32_t vec_size = std::gcd(16 / sizeof(DType), d);

  const uint32_t smem_size =
      sizeof(SamplingTempStorage<DType, BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO>);
  dim3 nblks(batch_size);
  dim3 nthrs(BLOCK_THREADS);
  void* args[] = {&draft_probs,
                  &draft_token_ids,
                  &target_probs,
                  &output_token_ids,
                  &output_accepted_token_num,
                  &output_emitted_token_num,
                  &num_speculative_tokens,
                  &d,
                  &philox_seed,
                  &philox_offset};
  DISPATCH_ALIGNED_VEC_SIZE(
      vec_size, VEC_SIZE, {DISPATCH_DETERMINISTIC(deterministic, DETERMINISTIC, {
        auto kernel = ChainSpeculativeSampling<BLOCK_THREADS, SCAN_ALGO, REDUCE_ALGO, VEC_SIZE,
                                               DETERMINISTIC, DType, IdType>;
        FLASHINFER_CUDA_CALL(
            cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
        FLASHINFER_CUDA_CALL(
            cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
      })});
  return cudaSuccess;
}

}  // namespace sampling

}  // namespace flashinfer

#endif  // FLASHINFER_SAMPLING_CUH_
