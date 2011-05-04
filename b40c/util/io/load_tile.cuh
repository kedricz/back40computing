/******************************************************************************
 * 
 * Copyright 2010-2011 Duane Merrill
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 * Thanks!
 * 
 ******************************************************************************/

/******************************************************************************
 * Kernel utilities for loading tiles of data through global memory
 * with cache modifiers
 ******************************************************************************/

#pragma once

#include <b40c/util/operators.cuh>
#include <b40c/util/vector_types.cuh>
#include <b40c/util/io/modified_load.cuh>

namespace b40c {
namespace util {
namespace io {


/**
 * Load a tile of items and initialize discontinuity flags
 */
template <
	int LOG_LOADS_PER_TILE, 									// Number of vector loads (log)
	int LOG_LOAD_VEC_SIZE,										// Number of items per vector load (log)
	int ACTIVE_THREADS,											// Active threads that will be loading
	ld::CacheModifier CACHE_MODIFIER>							// Cache modifier (e.g., CA/CG/CS/NONE/etc.)
struct LoadTile
{
	enum {
		LOADS_PER_TILE 		= 1 << LOG_LOADS_PER_TILE,
		LOAD_VEC_SIZE 		= 1 << LOG_LOAD_VEC_SIZE,
		TILE_SIZE 			= LOADS_PER_TILE * LOAD_VEC_SIZE,
	};
	
	//---------------------------------------------------------------------
	// Iteration Structures
	//---------------------------------------------------------------------

	template <bool FIRST_TILE, int LOAD, int VEC, int dummy = 0> struct Iterate;

	/**
	 * First vec element of a vector-load
	 */
	template <bool FIRST_TILE, int LOAD, int dummy>
	struct Iterate<FIRST_TILE, LOAD, 0, dummy>
	{
		// Regular (unguarded)
		template <typename T, void Transform(T&), typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadValid(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[],
			VectorType *d_in_vectors)
		{
			ModifiedLoad<CACHE_MODIFIER>::Ld(vectors[LOAD], d_in_vectors);
			Transform(data[LOAD][0]);		// Apply transform function with in_bounds = true
			if (flags) {
				flags[LOAD][0] = 1;
			}

			Iterate<FIRST_TILE, LOAD, 1>::template LoadValid<T, Transform>(
				data, flags, vectors, d_in_vectors);
		}

		// Regular (guarded)
		template <typename T, void Transform(T&), typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadValid(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements)
		{
			SizeT thread_offset = (threadIdx.x << LOG_LOAD_VEC_SIZE) + (LOAD * ACTIVE_THREADS * LOAD_VEC_SIZE) + 0;

			if (thread_offset < guarded_elements) {
				ModifiedLoad<CACHE_MODIFIER>::Ld(data[LOAD][0], d_in + thread_offset);
				Transform(data[LOAD][0]);
				if (flags) {
					flags[LOAD][0] = 1;
				}
			} else {
				if (flags) {
					flags[LOAD][0] = 0;
				}
			}

			Iterate<FIRST_TILE, LOAD, 1>::template LoadValid<T, Transform>(
				data, flags, d_in, guarded_elements);
		}

		// With discontinuity flags (unguarded)
		template <typename T, typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[], 
			VectorType *d_in_vectors) 
		{
			// Load the vector
			ModifiedLoad<CACHE_MODIFIER>::Ld(vectors[LOAD], d_in_vectors);

			// Process first vec element
			T current = data[LOAD][0];

			// Get the previous vector element
			T *d_ptr = (T*) d_in_vectors;
			T previous;
			ModifiedLoad<CACHE_MODIFIER>::Ld(previous, d_ptr - 1);

			// Initialize discontinuity flag
			flags[LOAD][0] = (previous != current);

			Iterate<FIRST_TILE, LOAD, 1>::LoadDiscontinuity(
				data, flags, vectors, d_in_vectors);
		}

		// With discontinuity flags (guarded)
		template <typename T, typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements)
		{
			SizeT thread_offset = (threadIdx.x << LOG_LOAD_VEC_SIZE) + (LOAD * ACTIVE_THREADS * LOAD_VEC_SIZE) + 0;

			if (thread_offset < guarded_elements) {
				ModifiedLoad<CACHE_MODIFIER>::Ld(data[LOAD][0], d_in + thread_offset);

				// Get the previous vector element (which is in range b/c this one is in range)
				T previous;
				ModifiedLoad<CACHE_MODIFIER>::Ld(previous, d_in + thread_offset - 1);
				flags[LOAD][0] = (previous != data[LOAD][0]);

			} else {
				flags[LOAD][0] = 0;
			}

			Iterate<FIRST_TILE, LOAD, 1>::LoadDiscontinuity(
				data, flags, d_in, guarded_elements);
		}
	};


	/**
	 * First vec element of first load of first tile
	 */
	template <int dummy>
	struct Iterate<true, 0, 0, dummy>
	{
		// With discontinuity flags (unguarded)
		template <typename T, typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[],
			VectorType *d_in_vectors)
		{
			// Load the vector
			ModifiedLoad<CACHE_MODIFIER>::Ld(vectors[0], d_in_vectors);

			// Process first vec element
			T current = data[0][0];

			if ((blockIdx.x == 0) && (threadIdx.x == 0)) {

				// First load of first tile of first CTA: discontinuity
				flags[0][0] = 1;

			} else {

				// Get the previous vector element
				T *d_ptr = (T*) d_in_vectors;
				T previous;
				ModifiedLoad<CACHE_MODIFIER>::Ld(previous, d_ptr - 1);

				// Initialize discontinuity flag
				flags[0][0] = (previous != current);
			}

			Iterate<true, 0, 1>::LoadDiscontinuity(
				data, flags, vectors, d_in_vectors);
		}

		// With discontinuity flags (guarded)
		template <typename T, typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements)
		{
			SizeT thread_offset = (threadIdx.x << LOG_LOAD_VEC_SIZE) + (0 * ACTIVE_THREADS * LOAD_VEC_SIZE) + 0;

			if (thread_offset < guarded_elements) {
				ModifiedLoad<CACHE_MODIFIER>::Ld(data[0][0], d_in + thread_offset);

				if ((blockIdx.x == 0) && (threadIdx.x == 0)) {

					// First load of first tile of first CTA: discontinuity
					flags[0][0] = 1;

				} else {

					// Get the previous vector element (which is in range b/c this one is in range)
					T previous;
					ModifiedLoad<CACHE_MODIFIER>::Ld(previous, d_in + thread_offset - 1);
					flags[0][0] = (previous != data[0][0]);
				}

			} else {
				flags[0][0] = 0;
			}

			Iterate<true, 0, 1>::LoadDiscontinuity(
				data, flags, d_in, guarded_elements);
		}
	};


	/**
	 * Next vec element of a vector-load
	 */
	template <bool FIRST_TILE, int LOAD, int VEC, int dummy>
	struct Iterate
	{
		// Regular (unguarded)
		template <typename T, void Transform(T&), typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadValid(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[],
			VectorType *d_in_vectors)
		{
			Transform(data[LOAD][VEC]);	// Apply transform function with in_bounds = true
			if (flags) {
				flags[LOAD][VEC] = 1;
			}

			Iterate<FIRST_TILE, LOAD, VEC + 1>::template LoadValid<T, Transform>(
				data, flags, vectors, d_in_vectors);
		}

		// Regular (guarded)
		template <typename T, void Transform(T&), typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadValid(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements)
		{
			SizeT thread_offset = (threadIdx.x << LOG_LOAD_VEC_SIZE) + (LOAD * ACTIVE_THREADS * LOAD_VEC_SIZE) + VEC;

			if (thread_offset < guarded_elements) {
				ModifiedLoad<CACHE_MODIFIER>::Ld(data[LOAD][VEC], d_in + thread_offset);
				Transform(data[LOAD][VEC]);
				if (flags) {
					flags[LOAD][0] = 1;
				}
			} else {
				if (flags) {
					flags[LOAD][0] = 0;
				}
			}

			Iterate<FIRST_TILE, LOAD, VEC + 1>::template LoadValid<T, Transform>(
				data, flags, d_in, guarded_elements);
		}

		// With discontinuity flags
		template <typename T, typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[], 
			VectorType *d_in_vectors)
		{
			T current = data[LOAD][VEC];
			T previous = data[LOAD][VEC - 1];
			flags[LOAD][VEC] = (previous != current);

			Iterate<FIRST_TILE, LOAD, VEC + 1>::LoadDiscontinuity(
				data, flags, vectors, d_in_vectors);
		}

		// With discontinuity flags
		template <typename T, typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements)
		{
			SizeT thread_offset = (threadIdx.x << LOG_LOAD_VEC_SIZE) + (LOAD * ACTIVE_THREADS * LOAD_VEC_SIZE) + VEC;

			if (thread_offset < guarded_elements) {
				ModifiedLoad<CACHE_MODIFIER>::Ld(data[LOAD][VEC], d_in + thread_offset);

				T previous = data[LOAD][VEC - 1];
				T current = data[LOAD][VEC];
				flags[LOAD][VEC] = (previous != current);

			} else {

				flags[LOAD][VEC] = 0;
			}

			Iterate<FIRST_TILE, LOAD, VEC + 1>::LoadDiscontinuity(
				data, flags, d_in, guarded_elements);
		}
	};


	/**
	 * Next load
	 */
	template <bool FIRST_TILE, int LOAD, int dummy>
	struct Iterate<FIRST_TILE, LOAD, LOAD_VEC_SIZE, dummy>
	{
		// Regular (unguarded)
		template <typename T, void Transform(T&), typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadValid(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[],
			VectorType *d_in_vectors)
		{
			Iterate<FIRST_TILE, LOAD + 1, 0>::template LoadValid<T, Transform>(
				data, flags, vectors, d_in_vectors + ACTIVE_THREADS);
		}

		// Regular (guarded)
		template <typename T, void Transform(T&), typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadValid(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements)
		{
			Iterate<FIRST_TILE, LOAD + 1, 0>::template LoadValid<T, Transform>(
				data, flags, d_in, guarded_elements);
		}

		// With discontinuity flags (unguarded)
		template <typename T, typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[], 
			VectorType *d_in_vectors)
		{
			Iterate<FIRST_TILE, LOAD + 1, 0>::LoadDiscontinuity(
				data, flags, vectors, d_in_vectors + ACTIVE_THREADS);
		}

		// With discontinuity flags (guarded)
		template <typename T, typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements)
		{
			Iterate<FIRST_TILE, LOAD + 1, 0>::LoadDiscontinuity(
				data, flags, d_in, guarded_elements);
		}
	};
	
	/**
	 * Terminate
	 */
	template <bool FIRST_TILE, int dummy>
	struct Iterate<FIRST_TILE, LOADS_PER_TILE, 0, dummy>
	{
		// Regular (unguarded)
		template <typename T, void Transform(T&), typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadValid(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[],
			VectorType *d_in_vectors) {}

		// Regular (guarded)
		template <typename T, void Transform(T&), typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadValid(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements) {}

		// With discontinuity flags (unguarded)
		template <typename T, typename Flag, typename VectorType>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			VectorType vectors[], 
			VectorType *d_in_vectors) {}

		// With discontinuity flags (guarded)
		template <typename T, typename Flag, typename SizeT>
		static __device__ __forceinline__ void LoadDiscontinuity(
			T data[][LOAD_VEC_SIZE],
			Flag flags[][LOAD_VEC_SIZE],
			T *d_in,
			const SizeT &guarded_elements) {}

	};


	//---------------------------------------------------------------------
	// Interface
	//---------------------------------------------------------------------

	/**
	 * Load a full tile with transform and set valid flags
	 */
	template <
		typename T,
		void Transform(T&),
		typename Flag>
	static __device__ __forceinline__ void LoadValid(
		T data[][LOAD_VEC_SIZE],
		Flag flags[][LOAD_VEC_SIZE],
		T *d_in)
	{
		// Use an aliased pointer to keys array to perform built-in vector loads
		typedef typename VecType<T, LOAD_VEC_SIZE>::Type VectorType;

		VectorType *vectors = (VectorType *) data;
		VectorType *d_in_vectors = (VectorType *) (d_in + (threadIdx.x << LOG_LOAD_VEC_SIZE));

		Iterate<false, 0,0>::template LoadValid<T, Transform>(
			data, flags, vectors, d_in_vectors);
	}

	/**
	 * Load a full tile with transform
	 */
	template <typename T, void Transform(T&)>
	static __device__ __forceinline__ void LoadValid(
		T data[][LOAD_VEC_SIZE],
		T *d_in)
	{
		LoadValid<T, Transform, int>(data, NULL, d_in);
	}

	/**
	 * Load a full tile and set valid flags
	 */
	template <typename T, typename Flag>
	static __device__ __forceinline__ void LoadValid(
		T data[][LOAD_VEC_SIZE],
		Flag flags[][LOAD_VEC_SIZE],
		T *d_in)
	{
		LoadValid<T, NopTransform<T> >(data, flags, d_in);
	}

	/**
	 * Load a full tile
	 */
	template <typename T>
	static __device__ __forceinline__ void LoadValid(
		T data[][LOAD_VEC_SIZE],
		T *d_in)
	{
		int (*flags)[LOAD_VEC_SIZE] = NULL;
		LoadValid(data, flags, d_in);
	}

	/**
	 * Load guarded_elements of a tile with transform and set valid flags
	 */
	template <
		typename T,
		void Transform(T&),
		typename Flag,
		typename SizeT>
	static __device__ __forceinline__ void LoadValid(
		T data[][LOAD_VEC_SIZE],
		Flag flags[][LOAD_VEC_SIZE],
		T *d_in,
		const SizeT &guarded_elements)
	{
		if (guarded_elements >= TILE_SIZE) {
			LoadValid<T, Transform>(data, flags, d_in);
		} else {
			Iterate<false, 0, 0>::template LoadValid<T, Transform>(
				data, flags, d_in, guarded_elements);
		}
	}

	/**
	 * Load guarded_elements of a tile with transform
	 */
	template <
		typename T,
		void Transform(T&),
		typename SizeT>
	static __device__ __forceinline__ void LoadValid(
		T data[][LOAD_VEC_SIZE],
		T *d_in,
		const SizeT &guarded_elements)
	{
		int (*flags)[LOAD_VEC_SIZE] = NULL;
		if (guarded_elements >= TILE_SIZE) {
			LoadValid<T, Transform, int>(data, flags, d_in, guarded_elements);
		} else {
			LoadValid<T, Transform, int>(data, flags, d_in);
		}
	}

	/**
	 * Load guarded_elements of a tile and set valid flags
	 */
	template <typename T, typename Flag, typename SizeT>
	static __device__ __forceinline__ void LoadValid(
		T data[][LOAD_VEC_SIZE],
		Flag flags[][LOAD_VEC_SIZE],
		T *d_in,
		const SizeT &guarded_elements)
	{
		if (guarded_elements >= TILE_SIZE) {
			LoadValid<T, NopTransform<T> >(data, flags, d_in, guarded_elements);
		} else {
			LoadValid<T, NopTransform<T> >(data, flags, d_in);
		}
	}

	/**
	 * Load guarded_elements of a tile
	 */
	template <typename T, typename SizeT>
	static __device__ __forceinline__ void LoadValid(
		T data[][LOAD_VEC_SIZE],
		T *d_in,
		const SizeT &guarded_elements)
	{
		if (guarded_elements >= TILE_SIZE) {
			LoadValid<T, NopTransform<T>, int>(data, NULL, d_in);
		} else {
			LoadValid<T, NopTransform<T>, int>(data, NULL, d_in, guarded_elements);
		}
	}



	/**
	 * Load a full tile and initialize discontinuity flags when values change
	 * between consecutive elements (unguarded)
	 */
	template <
		bool FIRST_TILE,											// Whether or not this is the first tile loaded by the CTA
		typename T,
		typename Flag>												// Integer type for indexing into global arrays
	static __device__ __forceinline__ void LoadDiscontinuity(
		T data[][LOAD_VEC_SIZE],
		Flag flags[][LOAD_VEC_SIZE],
		T *d_in)
	{
		// Use an aliased pointer to keys array to perform built-in vector loads
		typedef typename VecType<T, LOAD_VEC_SIZE>::Type VectorType;

		VectorType *vectors = (VectorType *) data;
		VectorType *d_in_vectors = (VectorType *) (d_in + (threadIdx.x << LOG_LOAD_VEC_SIZE));
		Iterate<FIRST_TILE, 0,0>::LoadDiscontinuity(data, flags, vectors, d_in_vectors);
	}

	/**
	 * Load guarded_elements of a tile and initialize discontinuity flags when
	 * values change between consecutive elements
	 */
	template <
		bool FIRST_TILE,								// Whether or not this is the first tile loaded by the CTA
		typename T,										// Tile type
		typename Flag,									// Discontinuity flag type
		typename SizeT>									// Integer type for indexing into global arrays
	static __device__ __forceinline__ void LoadDiscontinuity(
		T data[][LOAD_VEC_SIZE],
		Flag flags[][LOAD_VEC_SIZE],
		T *d_in,
		const SizeT &guarded_elements)
	{
		Iterate<FIRST_TILE, 0, 0>::LoadDiscontinuity(data, flags, d_in, guarded_elements);
	} 
};


} // namespace io
} // namespace util
} // namespace b40c
