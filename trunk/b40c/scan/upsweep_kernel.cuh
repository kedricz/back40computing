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
 ******************************************************************************/

/******************************************************************************
 * Upsweep reduction kernel for scan
 ******************************************************************************/

#pragma once

#include <b40c/util/cta_work_distribution.cuh>
#include <b40c/util/cta_work_progress.cuh>
#include <b40c/reduction/upsweep_cta.cuh>

namespace b40c {
namespace scan {


/**
 * Upsweep reduction pass
 */
template <typename KernelConfig>
__device__ __forceinline__ void UpsweepPass(
	typename KernelConfig::T 									*&d_in,
	typename KernelConfig::T 									*&d_out,
	util::CtaWorkDistribution<typename KernelConfig::SizeT> 	&work_decomposition)
{
	typedef reduction::UpsweepCta<KernelConfig> UpsweepCta;
	typedef typename KernelConfig::T T;
	typedef typename KernelConfig::SizeT SizeT;

	// Shared SRTS grid storage
	__shared__ uint4 reduction_tree[KernelConfig::SMEM_QUADS];

	// Quit if we're the last threadblock (no need for it in upsweep)
	if (blockIdx.x == gridDim.x - 1) {
		return;
	}

	// CTA processing abstraction
	UpsweepCta cta(reduction_tree, d_in, d_out);

	// Determine our threadblock's work range
	SizeT cta_offset;			// Offset at which this CTA begins processing
	SizeT cta_elements;			// Total number of elements for this CTA to process
	SizeT guarded_offset; 		// Offset of final, partially-full tile (requires guarded loads)
	SizeT guarded_elements;		// Number of elements in partially-full tile

	work_decomposition.GetCtaWorkLimits<KernelConfig::LOG_TILE_ELEMENTS, KernelConfig::LOG_SCHEDULE_GRANULARITY>(
		cta_offset, cta_elements, guarded_offset, guarded_elements);

	// Since we're not the last block: process at least one full tile of tile_elements
	cta.template ProcessFullTile<true>(cta_offset, 0);
	cta_offset += KernelConfig::TILE_ELEMENTS;

	// Process any other full tiles
	while (cta_offset < guarded_offset) {

		cta.ProcessFullTile<false>(cta_offset, 0);
		cta_offset += KernelConfig::TILE_ELEMENTS;
	}

	// Collectively reduce accumulated carry from each thread into output
	// destination (all thread have valid reduction partials)
	cta.OutputToSpine();
}


/******************************************************************************
 * Upsweep Reduction Kernel Entrypoint
 ******************************************************************************/

/**
 * Upsweep reduction kernel entry point
 */
template <typename KernelConfig>
__launch_bounds__ (KernelConfig::THREADS, KernelConfig::CTA_OCCUPANCY)
__global__
void UpsweepKernel(
	typename KernelConfig::T 									*d_in,
	typename KernelConfig::T 									*d_spine,
	util::CtaWorkDistribution<typename KernelConfig::SizeT> 	work_decomposition)
{
	UpsweepPass<KernelConfig>(d_in, d_spine, work_decomposition);
}


} // namespace scan
} // namespace b40c
