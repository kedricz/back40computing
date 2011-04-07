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
 * Tile-processing functionality for BFS expansion kernels
 ******************************************************************************/

#pragma once

#include <b40c/util/device_intrinsics.cuh>
#include <b40c/util/cta_work_progress.cuh>
#include <b40c/util/scan/cooperative_scan.cuh>
#include <b40c/util/io/modified_load.cuh>
#include <b40c/util/io/modified_store.cuh>
#include <b40c/util/io/load_tile.cuh>


namespace b40c {
namespace bfs {
namespace expand_atomic {


/**
 * Derivation of KernelConfig that encapsulates tile-processing routines
 */
template <typename KernelConfig>
struct SweepCta : KernelConfig
{
	//---------------------------------------------------------------------
	// Typedefs
	//---------------------------------------------------------------------

	typedef typename KernelConfig::VertexId 		VertexId;
	typedef typename KernelConfig::SizeT 			SizeT;
	typedef typename KernelConfig::SrtsDetails 		SrtsDetails;

	//---------------------------------------------------------------------
	// Members
	//---------------------------------------------------------------------

	// Current BFS iteration
	VertexId 				iteration;

	// Input and output device pointers
	VertexId 				*d_in;
	VertexId 				*d_out;
	VertexId				*d_column_indices;
	SizeT					*d_row_offsets;
	VertexId				*d_source_path;

	// Work progress
	util::CtaWorkProgress	&work_progress;

	// Operational details for SRTS scan grid
	SrtsDetails 			srts_details;

	volatile SizeT 			(&warp_comm)[KernelConfig::WARPS][3];


	//---------------------------------------------------------------------
	// Helper Structures
	//---------------------------------------------------------------------

	/**
	 * Tile
	 */
	template <
		int LOG_LOADS_PER_TILE,
		int LOG_LOAD_VEC_SIZE,
		bool FULL_TILE>
	struct Tile
	{
		//---------------------------------------------------------------------
		// Typedefs and Constants
		//---------------------------------------------------------------------

		enum {
			LOADS_PER_TILE 		= 1 << LOG_LOADS_PER_TILE,
			LOAD_VEC_SIZE 		= 1 << LOG_LOAD_VEC_SIZE
		};

		typedef typename util::VecType<SizeT, 2>::Type Vec2SizeT;


		//---------------------------------------------------------------------
		// Members
		//---------------------------------------------------------------------

		// Dequeued vertex ids
		VertexId 	vertex_id[LOADS_PER_TILE][LOAD_VEC_SIZE];

		// Edge list details
		SizeT		row_offset[LOADS_PER_TILE][LOAD_VEC_SIZE];
		SizeT		row_length[LOADS_PER_TILE][LOAD_VEC_SIZE];
		SizeT		row_rank[LOADS_PER_TILE][LOAD_VEC_SIZE];


		//---------------------------------------------------------------------
		// Helper Structures
		//---------------------------------------------------------------------

		/**
		 * Iterate next vector element
		 */
		template <int LOAD, int VEC, int dummy = 0>
		struct Iterate
		{
			/**
			 * Init
			 */
			static __device__ __forceinline__ void Init(Tile *tile)
			{
				tile->row_length[LOAD][VEC] = 0;

				Iterate<LOAD, VEC + 1>::Init(tile);
			}

			/**
			 * Inspect
			 */
			static __device__ __forceinline__ void Inspect(SweepCta *cta, Tile *tile)
			{
				if (FULL_TILE || (tile->vertex_id[LOAD][VEC] != -1)) {

					// Load source path of node
					VertexId source_path;
					util::io::ModifiedLoad<util::io::ld::cg>::Ld(
						source_path,
						cta->d_source_path + tile->vertex_id[LOAD][VEC]);

					// Load neighbor row range from d_row_offsets
					Vec2SizeT row_range;
					if (tile->vertex_id[LOAD][VEC] & 1) {

						// Misaligned: load separately
						util::io::ModifiedLoad<util::io::ld::ca>::Ld(
							row_range.x,
							cta->d_row_offsets + tile->vertex_id[LOAD][VEC]);

						util::io::ModifiedLoad<util::io::ld::ca>::Ld(
							row_range.y,
							cta->d_row_offsets + tile->vertex_id[LOAD][VEC] + 1);

					} else {
						// Aligned: load together
						util::io::ModifiedLoad<util::io::ld::cg>::Ld(
							row_range,
							reinterpret_cast<Vec2SizeT*>(cta->d_row_offsets + tile->vertex_id[LOAD][VEC]));
					}

					if (source_path == -1) {
/*
						printf("\t\tIteration %d block %d thread %d found unexplored vertex %d\n",
							cta->iteration, blockIdx.x, threadIdx.x, tile->vertex_id[LOAD][VEC]);
*/
						// Node is previously unvisited: compute row offset and length
						tile->row_offset[LOAD][VEC] = row_range.x;
						tile->row_length[LOAD][VEC] = row_range.y - row_range.x;

						// Update source path with current iteration
						util::io::ModifiedStore<util::io::st::cg>::St(
							cta->iteration,
							cta->d_source_path + tile->vertex_id[LOAD][VEC]);
					}
				}
				tile->row_rank[LOAD][VEC] = tile->row_length[LOAD][VEC];

				Iterate<LOAD, VEC + 1>::Inspect(cta, tile);
			}


			/**
			 * Expand
			 */
			static __device__ __forceinline__ void Expand(SweepCta *cta, Tile *tile)
			{
				// CTA-based expansion/loading
				while (__syncthreads_or(tile->row_length[LOAD][VEC] > KernelConfig::THREADS)) {

					if (tile->row_length[LOAD][VEC] > KernelConfig::THREADS) {
						// Vie for control of the CTA
						cta->warp_comm[0][0] = threadIdx.x;
					}

					__syncthreads();

					if (threadIdx.x == cta->warp_comm[0][0]) {
						// Got control of the CTA
						cta->warp_comm[0][0] = tile->row_offset[LOAD][VEC];										// start
						cta->warp_comm[0][1] = tile->row_rank[LOAD][VEC];										// queue rank
						cta->warp_comm[0][2] = tile->row_offset[LOAD][VEC] + tile->row_length[LOAD][VEC];		// oob

						tile->row_length[LOAD][VEC] = 0;
					}

					__syncthreads();

					SizeT coop_offset 	= cta->warp_comm[0][0] + threadIdx.x;
					SizeT coop_rank	 	= cta->warp_comm[0][1] + threadIdx.x;
					SizeT coop_oob 		= cta->warp_comm[0][2];

					// Gather
					VertexId node_id;
					while (coop_offset < coop_oob) {

						util::io::ModifiedLoad<util::io::ld::NONE>::Ld(
							node_id, cta->d_column_indices + coop_offset);

						// Scatter
						util::io::ModifiedStore<KernelConfig::WRITE_MODIFIER>::St(
							node_id, cta->d_out + coop_rank);

						coop_offset += KernelConfig::THREADS;
						coop_rank += KernelConfig::THREADS;
					}
				}

				// Warp-based expansion/loading
				int warp_id = threadIdx.x >> B40C_LOG_WARP_THREADS(KernelConfig::CUDA_ARCH);
				int lane_id = util::LaneId();

				while (__any(tile->row_length[LOAD][VEC])) {

					if (tile->row_length[LOAD][VEC]) {
						// Vie for control of the warp
						cta->warp_comm[warp_id][0] = lane_id;
					}

					if (lane_id == cta->warp_comm[warp_id][0]) {

						// Got control of the warp
						cta->warp_comm[warp_id][0] = tile->row_offset[LOAD][VEC];									// start
						cta->warp_comm[warp_id][1] = tile->row_rank[LOAD][VEC];									// queue rank
						cta->warp_comm[warp_id][2] = tile->row_offset[LOAD][VEC] + tile->row_length[LOAD][VEC];	// oob

						tile->row_length[LOAD][VEC] = 0;
					}

					SizeT coop_offset 	= cta->warp_comm[warp_id][0] + lane_id;
					SizeT coop_rank 	= cta->warp_comm[warp_id][1] + lane_id;
					SizeT coop_oob 		= cta->warp_comm[warp_id][2];

					// Gather
					VertexId node_id;
					while (coop_offset < coop_oob) {

						util::io::ModifiedLoad<util::io::ld::NONE>::Ld(
							node_id, cta->d_column_indices + coop_offset);
/*
						printf("\t\t\tIteration %d block %d thread %d laneid %d enqueued vertex %d @ %llu\n",
							cta->iteration, blockIdx.x, threadIdx.x, lane_id, node_id, (unsigned long long) (cta->d_out + coop_rank));
*/
						// Scatter
						util::io::ModifiedStore<KernelConfig::WRITE_MODIFIER>::St(
							node_id, cta->d_out + coop_rank);

						coop_offset += B40C_WARP_THREADS(KernelConfig::CUDA_ARCH);
						coop_rank += B40C_WARP_THREADS(KernelConfig::CUDA_ARCH);
					}
				}

				// Next vector element
				Iterate<LOAD, VEC + 1>::Expand(cta, tile);
			}
		};

		/**
		 * Iterate next load
		 */
		template <int LOAD, int dummy>
		struct Iterate<LOAD, LOAD_VEC_SIZE, dummy>
		{
			/**
			 * Init
			 */
			static __device__ __forceinline__ void Init(Tile *tile)
			{
				Iterate<LOAD + 1, 0>::Init(tile);
			}

			/**
			 * Inspect
			 */
			static __device__ __forceinline__ void Inspect(SweepCta *cta, Tile *tile)
			{
				Iterate<LOAD + 1, 0>::Inspect(cta, tile);
			}

			/**
			 * Expand
			 */
			static __device__ __forceinline__ void Expand(SweepCta *cta, Tile *tile)
			{
				Iterate<LOAD + 1, 0>::Expand(cta, tile);
			}
		};

		/**
		 * Terminate
		 */
		template <int dummy>
		struct Iterate<LOADS_PER_TILE, 0, dummy>
		{
			// Init
			static __device__ __forceinline__ void Init(Tile *tile) {}

			// Inspect
			static __device__ __forceinline__ void Inspect(SweepCta *cta, Tile *tile) {}

			// Expand
			static __device__ __forceinline__ void Expand(SweepCta *cta, Tile *tile) {}
		};


		//---------------------------------------------------------------------
		// Interface
		//---------------------------------------------------------------------

		/**
		 * Constructor
		 */
		__device__ __forceinline__ Tile()
		{
			Iterate<0, 0>::Init(this);
		}

		/**
		 * Inspect dequeued vertices, updating source path if necessary and
		 * obtaining edge-list details
		 */
		__device__ __forceinline__ void Inspect(SweepCta *cta)
		{
			Iterate<0, 0>::Inspect(cta, this);
		}

		/**
		 * Expands neighbor lists for valid vertices
		 */
		__device__ __forceinline__ void Expand(SweepCta *cta)
		{
			Iterate<0, 0>::Expand(cta, this);
		}
	};


	//---------------------------------------------------------------------
	// Methods
	//---------------------------------------------------------------------

	/**
	 * Constructor
	 */
	template <typename SmemStorage>
	__device__ __forceinline__ SweepCta(
		VertexId 				iteration,
		SmemStorage 			&smem_storage,
		VertexId 				*d_in,
		VertexId 				*d_out,
		VertexId 				*d_column_indices,
		SizeT 					*d_row_offsets,
		VertexId 				*d_source_path,
		util::CtaWorkProgress	&work_progress) :

			srts_details(
				smem_storage.smem_pool_int4s,
				smem_storage.warpscan,
				0),
			warp_comm(smem_storage.warp_comm),
			iteration(iteration),
			d_in(d_in),
			d_out(d_out),
			d_column_indices(d_column_indices),
			d_row_offsets(d_row_offsets),
			d_source_path(d_source_path),
			work_progress(work_progress) {}


	/**
	 * Converts out-of-bounds vertex-ids to -1
	 */
	static __device__ __forceinline__ void LoadTransform(
		VertexId &vertex_id,
		bool in_bounds)
	{
		if (!in_bounds) {
			vertex_id = -1;
		}
	}


	/**
	 * Process a single tile
	 */
	template <bool FULL_TILE>
	__device__ __forceinline__ void ProcessTile(
		SizeT cta_offset,
		SizeT out_of_bounds = 0)
	{
		Tile<
			KernelConfig::LOG_LOADS_PER_TILE,
			KernelConfig::LOG_LOAD_VEC_SIZE,
			FULL_TILE> tile;

		// Load tile
		util::io::LoadTile<
			KernelConfig::LOG_LOADS_PER_TILE,
			KernelConfig::LOG_LOAD_VEC_SIZE,
			KernelConfig::THREADS,
			KernelConfig::READ_MODIFIER,
			FULL_TILE>::template Invoke<VertexId, LoadTransform>(
				tile.vertex_id,
				d_in,
				cta_offset,
				out_of_bounds);

		// Inspect dequeued vertices, updating source path and obtaining
		// edge-list details
		tile.Inspect(this);

		// Scan tile of row ranks (lengths) with enqueue reservation,
		// turning them into enqueue offsets
		util::scan::CooperativeTileScan<
			SrtsDetails,
			KernelConfig::LOAD_VEC_SIZE,
			true,							// exclusive
			util::DefaultSum>::ScanTileWithEnqueue(
				srts_details,
				tile.row_rank,
				work_progress.GetQueueCounter<SizeT>(iteration + 1));

		// Enqueue valid edge lists into outgoing queue
		tile.Expand(this);
	}
};



} // namespace expand_atomic
} // namespace bfs
} // namespace b40c
