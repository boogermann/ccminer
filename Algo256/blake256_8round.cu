/**
 * Optimized Blake-256 8-rounds Cuda Kernel (Tested on SM >3.0)
 * Based upon Blake-256 implementation of Tanguy Pruvot - Nov. 2014
 *
 * Provos Alexis - Jan. 2016
 * Reviewed by tpruvot - Feb 2016
 * 
 * Fixed CUDA 7.5 flaw
 * minor code changes
 * code cleanup
 * replaced SSE2 midstate computation with SPH
 * Provos Alexis - Mar 2016
 *
 * Minor boost
 * Provos Alexis - Apr 2016 
 */

#include <stdint.h>
#include <memory.h>

#include "miner.h"

extern "C" {
#include "sph/sph_blake.h"
}

#include "cuda_helper.h"

#ifdef __INTELLISENSE__
#define __byte_perm(x, y, b) x
#endif

/* threads per block and nonces per thread */
#define TPB 768
#define NPT 384
#define NBN 1

__constant__ uint32_t _ALIGN(16) d_data[21];

/* 8 adapters max */
static uint32_t		*d_resNonce[MAX_GPUS];
static uint32_t		*h_resNonce[MAX_GPUS];

/* hash by cpu with blake 256 */
extern "C" void blake256_8roundHash(void *output, const void *input){
	uchar hash[64];
	sph_blake256_context ctx;

	sph_blake256_set_rounds(8);

	sph_blake256_init(&ctx);
	sph_blake256(&ctx, input, 80);
	sph_blake256_close(&ctx, hash);

	memcpy(output, hash, 32);
}
#define GS4(a,b,c,d,x,y,a1,b1,c1,d1,x1,y1,a2,b2,c2,d2,x2,y2,a3,b3,c3,d3,x3,y3) { \
	v[ a]+= (m[ x] ^ z[ y]) + v[ b];		v[a1]+= (m[x1] ^ z[y1]) + v[b1];		v[a2]+= (m[x2] ^ z[y2]) + v[b2]; 		v[a3]+= (m[x3] ^ z[y3]) + v[b3]; \
	v[ d] = __byte_perm(v[ a] ^ v[ d], 0, 0x1032);	v[d1] = __byte_perm(v[a1] ^ v[d1], 0, 0x1032);	v[d2] = __byte_perm(v[a2] ^ v[d2], 0, 0x1032);	v[d3] = __byte_perm(v[a3] ^ v[d3], 0, 0x1032); \
	v[ c]+= v[ d];					v[c1]+= v[d1];					v[c2]+= v[d2];					v[c3]+= v[d3]; \
	v[ b] = ROTR32(v[ b] ^ v[ c], 12);		v[b1] = ROTR32(v[b1] ^ v[c1], 12);		v[b2] = ROTR32(v[b2] ^ v[c2], 12);		v[b3] = ROTR32(v[b3] ^ v[c3], 12); \
	v[ a]+= (m[ y] ^ z[ x]) + v[ b];		v[a1]+= (m[y1] ^ z[x1]) + v[b1];		v[a2]+= (m[y2] ^ z[x2]) + v[b2];		v[a3]+= (m[y3] ^ z[x3]) + v[b3]; \
	v[ d] = __byte_perm(v[ a] ^ v[ d], 0, 0x0321);	v[d1] = __byte_perm(v[a1] ^ v[d1], 0, 0x0321);	v[d2] = __byte_perm(v[a2] ^ v[d2], 0, 0x0321);	v[d3] = __byte_perm(v[a3] ^ v[d3], 0, 0x0321); \
	v[ c]+= v[ d];					v[c1]+= v[d1];					v[c2]+= v[d2];					v[c3]+= v[d3]; \
	v[ b] = ROTR32(v[ b] ^ v[ c], 7);		v[b1] = ROTR32(v[b1] ^ v[c1], 7);		v[b2] = ROTR32(v[b2] ^ v[c2], 7);		v[b3] = ROTR32(v[b3] ^ v[c3], 7); \
}

__global__
void blake256_8round_gpu_hash(const uint32_t threads, const uint32_t startNonce, uint32_t *resNonce,const uint64_t highTarget){
	uint32_t v[16];
	uint32_t tmp[16];

	const uint64_t thread   = blockDim.x * blockIdx.x + threadIdx.x;
	const uint64_t step     = gridDim.x * blockDim.x;
	const uint64_t maxNonce = startNonce + threads;

	const uint32_t z[16] = {
		0x243F6A88, 0x85A308D3, 0x13198A2E, 0x03707344, 0xA4093822, 0x299F31D0, 0x082EFA98, 0xEC4E6C89,
		0x452821E6, 0x38D01377, 0xBE5466CF, 0x34E90C6C, 0xC0AC29B7, 0xC97C50DD, 0x3F84D5B5, 0xB5470917
	};

//PREFETCH
	#pragma unroll
	for(int i=0;i<16;i++){
		tmp[ i] = d_data[ i];
	}

	uint32_t m[16] = {
				  d_data[16],	d_data[17],	d_data[18],	0,
				  0x80000000,	0,		0,		0,
				  0,		0,		0,		0,
				  0,		1,		0,		640
	};		

	const uint32_t h7 = d_data[19];
	const uint32_t h6 = d_data[20];
//END OF PREFETCH
	for(uint64_t m3 = startNonce + thread; m3<maxNonce;m3+=step){

		m[3]  = m3;
		
		#pragma unroll
		for(int i=0;i<16;i++)
			v[ i] = tmp[ i];

		v[ 1]+= m[3] ^ z[2];
		v[13] = __byte_perm(v[13] ^ v[ 1],0, 0x0321);
		v[ 9]+= v[13];
		v[ 5] = ROTR32(v[ 5] ^ v[ 9], 7);
		v[ 0]+= v[ 5];
		v[15] = __byte_perm(v[15] ^ v[ 0],0, 0x1032);
	
		v[10]+= v[15];
		v[ 5] = ROTR32(v[ 5] ^ v[10], 12);
		v[ 0]+= z[8] + v[ 5];
		v[15] = __byte_perm(v[15] ^ v[ 0],0, 0x0321);
		v[10]+= v[15];
		v[ 5] = ROTR32(v[ 5] ^ v[10], 7);

		v[ 1] += (m[10] ^ z[11]) + v[ 6];
		v[13] = __byte_perm(v[13] ^ v[ 2],0, 0x1032);
		v[12] = __byte_perm(v[12] ^ v[ 1],0, 0x1032);
		v[ 8] += v[13];
		v[11] += v[12];
		v[ 9] += v[14];
		v[ 7] = ROTR32(v[ 7] ^ v[ 8], 12);
		v[ 6] = ROTR32(v[ 6] ^ v[11], 12);
		v[ 4] = ROTR32(v[ 4] ^ v[ 9], 12);
		v[ 2] += (m[13] ^ z[12]) + v[ 7];
		v[ 1] += (m[11] ^ z[10]) + v[ 6];
		v[ 3] += (m[15] ^ z[14]) + v[ 4];
		v[13] = __byte_perm(v[13] ^ v[ 2],0, 0x0321);
		v[12] = __byte_perm(v[12] ^ v[ 1],0, 0x0321);
		v[14] = __byte_perm(v[14] ^ v[ 3],0, 0x0321);
		v[ 8] += v[13];
		v[11] += v[12];
		v[ 9] += v[14];
		v[ 7] = ROTR32(v[ 7] ^ v[ 8], 7);
		v[ 6] = ROTR32(v[ 6] ^ v[11], 7);
		v[ 4] = ROTR32(v[ 4] ^ v[ 9], 7);		

		GS4(0, 4, 8,12,	14,10,		1, 5, 9,13,	 4, 8,		2, 6,10,14,	 9,15,		3, 7,11,15,	13, 6);
		GS4(0, 5,10,15,	 1,12,		1, 6,11,12,	 0, 2,		2, 7, 8,13,	11, 7,		3, 4, 9,14,	 5, 3);
		GS4(0, 4, 8,12,	11, 8,		1, 5, 9,13,	12, 0,		2, 6,10,14,	 5, 2,		3, 7,11,15,	15,13);
		GS4(0, 5,10,15,	10,14,		1, 6,11,12,	 3, 6,		2, 7, 8,13,	 7, 1,		3, 4, 9,14,	 9, 4);
		GS4(0, 4, 8,12,	 7, 9,		1, 5, 9,13,	 3, 1,		2, 6,10,14,	13,12,		3, 7,11,15,	11,14);
		GS4(0, 5,10,15,	 2, 6,		1, 6,11,12,	 5,10,		2, 7, 8,13,	 4, 0,		3, 4, 9,14,	15, 8);
		GS4(0, 4, 8,12,	 9, 0,		1, 5, 9,13,	 5, 7,		2, 6,10,14,	 2, 4,		3, 7,11,15,	10,15);
		GS4(0, 5,10,15,	14, 1,		1, 6,11,12,	11,12,		2, 7, 8,13,	 6, 8,		3, 4, 9,14,	 3,13);
		GS4(0, 4, 8,12,	 2,12,		1, 5, 9,13,	 6,10,		2, 6,10,14,	 0,11,		3, 7,11,15,	 8, 3);
		GS4(0, 5,10,15,	 4,13,		1, 6,11,12,	 7, 5,		2, 7, 8,13,	15,14,		3, 4, 9,14,	 1, 9);
		GS4(0, 4, 8,12,	12, 5,		1, 5, 9,13,	 1,15,		2, 6,10,14,	14,13,		3, 7,11,15,	 4,10);
		GS4(0, 5,10,15,	 0, 7,		1, 6,11,12,	 6, 3,		2, 7, 8,13,	 9, 2,		3, 4, 9,14,	 8,11);
		GS4(0, 4, 8,12,	13,11,		1, 5, 9,13,	 7,14,		2, 6,10,14,	12, 1,		3, 7,11,15,	 3, 9);
		
		v[ 0] += (m[ 5] ^ z[0]) + v[ 5];
		v[ 2] += (m[ 8] ^ z[6]) + v[ 7];
		v[15] = __byte_perm(v[15] ^ v[ 0],0, 0x1032);			
		v[13] = __byte_perm(v[13] ^ v[ 2],0, 0x1032);
		v[10] += v[15];
		v[ 8] += v[13];
		v[ 5] = ROTR32(v[ 5] ^ v[10], 12);
		v[ 7] = ROTR32(v[ 7] ^ v[ 8], 12);
		v[ 0] += (m[ 0] ^ z[5]) + v[ 5];
		v[ 2] += (m[ 6] ^ z[8]) + v[ 7];
		v[13] = __byte_perm(v[13] ^ v[ 2],0, 0x0321);
		v[15] = ROTR32(v[15] ^ v[ 0],1);
				
		v[ 8] += v[13];
		// only compute h6 & 7
		if(xor3x(v[ 8],h7,v[ 7])==v[15]){
			v[ 1] += (m[15] ^ z[ 4]) + v[ 6];
			v[ 3] += (z[10] ^ m[ 2]) + v[ 4];
			v[12]  = __byte_perm(v[12] ^ v[ 1],0, 0x1032);
			v[14]  = __byte_perm(v[14] ^ v[ 3],0, 0x1032);
			v[11] += v[12];
			v[ 9] += v[14];
			v[ 6]  = ROTR32(v[ 6] ^ v[11], 12);
			
			v[ 1] += (m[ 4] ^ z[15]) + v[ 6];
		
			v[ 3] += (m[10] ^ z[ 2]) + ROTR32(v[ 4] ^ v[ 9],12);
			v[11] += __byte_perm(v[12] ^ v[ 1],0, 0x0321);
		
			v[ 6] = ROTR32(v[ 6] ^ v[11], 7);
			v[14]  = __byte_perm(v[14] ^ v[ 3],0, 0x1230);
			v[ 6] = __byte_perm(v[ 6], 0,0x0123);
		
			if(xor3x(h6,v[14],v[ 6]) <= highTarget){
#if NBN == 2
				/* keep the smallest nonce, + extra one if found */
				if (m[3] < resNonce[0]){
					resNonce[1] = resNonce[0];
					resNonce[0] = m[3];
				}
				else
					resNonce[1] = m[3];
#else
				resNonce[0] = m[3];
#endif
				return; //<-- this may cause a problem on extranonce if the extranonce is on position current_nonce + X * step where X=[1,2,3..,N]
			}
		}
	}
}

__host__
void blake256_8round_cpu_setBlock_16(const int thr_id,const uint32_t* endiandata, uint32_t *penddata){

	const uint32_t _ALIGN(64) z[16] = {
		SPH_C32(0x243F6A88), SPH_C32(0x85A308D3), SPH_C32(0x13198A2E), SPH_C32(0x03707344),
		SPH_C32(0xA4093822), SPH_C32(0x299F31D0), SPH_C32(0x082EFA98), SPH_C32(0xEC4E6C89),
		SPH_C32(0x452821E6), SPH_C32(0x38D01377), SPH_C32(0xBE5466CF), SPH_C32(0x34E90C6C),
		SPH_C32(0xC0AC29B7), SPH_C32(0xC97C50DD), SPH_C32(0x3F84D5B5), SPH_C32(0xB5470917)
	};
	uint32_t _ALIGN(64) h[22];

	sph_blake256_context ctx;

	sph_blake256_set_rounds(8);

	sph_blake256_init(&ctx);
	sph_blake256(&ctx, endiandata, 64);
	
	h[ 0] = ctx.H[0];	h[ 1] = ctx.H[1];
	h[ 2] = ctx.H[2];	h[21] = ctx.H[3];
	h[ 4] = ctx.H[4];	h[20] = ctx.H[5];
	h[19] = ctx.H[6];	h[16] = ctx.H[7];

	uint32_t tmp = h[20];
	h[20] = h[19];
	h[19] = h[16];
	h[16] = penddata[ 0];
	h[17] = penddata[ 1];
	h[18] = penddata[ 2];
	h[12] = z[ 4] ^ 640;
	h[ 8] = z[ 0];

	h[ 0] += (h[16] ^ z[ 1]) + h[ 4];
	h[12]  = SPH_ROTR32(h[12] ^ h[0],16);
	h[ 8] += h[12];
	h[ 4]  = SPH_ROTR32(h[ 4] ^ h[ 8], 12);
	h[ 0] += (h[17] ^ z[ 0]) + h[ 4];
	h[12]  = SPH_ROTR32(h[12] ^ h[0],8);
	h[ 8] += h[12];
	h[ 4]  = SPH_ROTR32(h[ 4] ^ h[ 8], 7);

	h[1] += (h[18] ^ z[ 3]) + tmp;

	h[13] = SPH_ROTR32(z[ 5] ^ 640 ^ h[1],16);
	h[ 5] = ROTR32(tmp ^ (z[ 1] + h[13]), 12);

	h[ 1] += h[ 5];
	h[ 2] += (0x80000000UL ^ z[ 5]) + h[20];

	h[14]  = SPH_ROTR32(z[ 6] ^ h[2], 16);
	h[ 6]  = z[ 2] + h[14];
	h[ 6]  = SPH_ROTR32(h[20] ^ h[ 6], 12);

	h[21] += z[ 7] + h[19];
	h[ 0] += z[ 9];

	h[ 2] += z[ 4] + h[ 6];

	h[ 9] = z[ 1] + h[13];
	h[10] = z[ 2] + h[14];
	
	h[14] = SPH_ROTR32(h[14] ^ h[2],8); //0x0321
	h[10]+=h[14];
	
	h[ 6] = SPH_ROTR32(h[ 6] ^ h[10],7);
	h[15] = SPH_ROTR32(z[ 7] ^ h[21],16);
	
	h[11] = z[ 3] + h[15];
	h[ 7] = SPH_ROTR32(h[19] ^ h[11], 12);
	h[ 3] = h[21] + h[ 7] + z[ 6];
	
	h[15] = SPH_ROTR32(h[15] ^ h[ 3],8);
	h[11]+= h[15];
	h[ 7] = ROTR32(h[ 7] ^ h[11],7);

	h[ 2]+= z[13];
	h[ 3]+= z[15];	
	h[ 2]+= h[ 7];
	h[ 3]+= h[ 4];
	h[14] = SPH_ROTR32(h[14] ^ h[ 3], 16);
	
	h[19] = ROTL32(h[19],7); //align the rotation with v[7] v[15];
	h[20] = sph_bswap32(h[20]);
	cudaMemcpyToSymbol(d_data, h, 21*sizeof(uint32_t), 0, cudaMemcpyHostToDevice);
}

static bool init[MAX_GPUS] = { 0 };

extern "C" int scanhash_blake256_8round(int thr_id, struct work* work, uint32_t max_nonce, unsigned long *hashes_done){
	uint32_t *pdata = work->data;
	uint32_t *ptarget = work->target;
	const uint32_t first_nonce  = pdata[19];
	const uint32_t targetHigh   = ptarget[6];
	int dev_id = device_map[thr_id];

	if (!init[thr_id]) {
		cudaSetDevice(dev_id);
		if (opt_cudaschedule == -1 && gpu_threads == 1) {
			cudaDeviceReset();
			// reduce cpu usage (linux)
			cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
			cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
			CUDA_LOG_ERROR();
		}
		CUDA_CALL_OR_RET_X(cudaMalloc(&d_resNonce[thr_id], NBN * sizeof(uint32_t)), -1);
		CUDA_CALL_OR_RET_X(cudaMallocHost(&h_resNonce[thr_id], NBN * sizeof(uint32_t)), -1);
		init[thr_id] = true;
	}

	uint32_t _ALIGN(64) endiandata[20];

	for (int k = 0; k < 16; k++)
		be32enc(&endiandata[k], pdata[k]);
		
	cudaMemset(d_resNonce[thr_id], 0xff, sizeof(uint32_t));

	blake256_8round_cpu_setBlock_16(thr_id,endiandata,&pdata[16]);

	int intensity = (device_sm[dev_id] > 500 && !is_windows()) ? 30 : 24;
	if (device_sm[dev_id] < 350) intensity = 22;
	uint32_t throughput = cuda_default_throughput(thr_id, 1U << intensity);
	if (init[thr_id]) throughput = min(throughput, max_nonce - first_nonce);
	
	const dim3 grid((throughput + (NPT*TPB)-1)/(NPT*TPB));
	const dim3 block(TPB);
	int rc = 0;

	do {
		blake256_8round_gpu_hash<<<grid,block>>>(throughput, pdata[19], d_resNonce[thr_id], targetHigh);
		cudaMemcpy(h_resNonce[thr_id], d_resNonce[thr_id], NBN*sizeof(uint32_t), cudaMemcpyDeviceToHost);
		
		if (h_resNonce[thr_id][0] != UINT32_MAX){
			uint32_t vhashcpu[8];
			uint32_t Htarg = (uint32_t)targetHigh;

			for (int k=0; k < 19; k++)
				be32enc(&endiandata[k], pdata[k]);

			be32enc(&endiandata[19], h_resNonce[thr_id][0]);
			blake256_8roundHash(vhashcpu, endiandata);

			if (vhashcpu[6] <= Htarg && fulltest(vhashcpu, ptarget)){
				rc = 1;
				work_set_target_ratio(work, vhashcpu);
				*hashes_done = pdata[19] - first_nonce + throughput;
				pdata[19] = h_resNonce[thr_id][0];
#if NBN > 1
				if (h_resNonce[thr_id][1] != UINT32_MAX) {
					pdata[21] = h_resNonce[thr_id][1];
					applog(LOG_BLUE, "1:%x 2:%x", h_resNonce[thr_id][0], h_resNonce[thr_id][1]);
					rc = 2;
				}
#endif
//				gpulog(LOG_INFO,thr_id, "ptarget7 %08x ptarget6 %08x",ptarget[7],targetHigh);
				return rc;
			}
			else {
				gpulog(LOG_WARNING, thr_id, "result for %08x does not validate on CPU!", h_resNonce[thr_id][0]);
			}
		}

		pdata[19] += throughput;
	} while (!work_restart[thr_id].restart && ((uint64_t)max_nonce > ((uint64_t)(pdata[19]) + (uint64_t)throughput)));

	*hashes_done = pdata[19] - first_nonce;
	MyStreamSynchronize(NULL, 0, dev_id);
	return rc;
}

// cleanup
extern "C" void free_blake256_8round(int thr_id)
{
	if (!init[thr_id])
		return;

	cudaDeviceSynchronize();

	cudaFreeHost(h_resNonce[thr_id]);
	cudaFree(d_resNonce[thr_id]);

	init[thr_id] = false;

	cudaDeviceSynchronize();
}
