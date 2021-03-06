//Doesn't sieve for >1024 threads
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>

typedef unsigned __int64 integer;
const size_t size = sizeof(integer);
const integer pow2_32 = 4294967296;
const int threads = 256;

//Utility function to calculate postive integer-powers
integer power(integer val, integer exp)
{
	integer temp = val;
	for (integer i = 1; i < exp; i++) temp *= val;
	return temp;
}

//Utility function to approximate no. of primes between 1->n as n/ln(n)
integer trimSize(integer n)
{
	long double e = 2.7183;
	integer exp = 1;
	while (pow(e, exp) < n)
		exp++;
	return n / (exp - 2);
}

///////////////////////////KERNEL START///////////////////////////
__device__ void SievePrime(bool *mark, integer p, integer min, integer minb, integer max)
{
	integer j;
	for (j = minb;j <= max;j += (p << 1))
		mark[(j - min) >> 1] = true;
}
__global__ void SieveBlock(integer *P, integer completed)
{
	integer id = threadIdx.x, i, j, minb;
	integer segsize = pow2_32 / threads;
	integer min = (completed * pow2_32) + (id * segsize) + 1;
	integer max = min + segsize - 2;
	bool mark[(pow2_32 >> 1) / threads];
	
	for (i = 0;P[i] * P[i] <= max;i++)
	{
		minb = (min / P[i]) * (P[i]) + P[i];
		if (~minb & 1)	minb += P[i];
		for (j = minb;j <= max;j += (P[i] << 1))
			mark[(j - min + 1) >> 1] = true;
	}
	//printf("Kernel %3llu stopped at %llu [Max: %llu]\n", id + completed, j - (P[i] << 2), max);
	for (j = max; j >= min; j -= 2)
	{
		if (!mark[(j - min + 1) >> 1])
		{
			printf("Test\n");
			//printf("Kernel %llu: %llu\n", id , j);
			break;
		}
	}
}
////////////////////////////KERNEL END////////////////////////////

//     SEGMENTED SIEVE
//	n		RAM	    Time
// E07	   552KB   0.026s
// E08	   620KB   0.206s
// E09	   704KB   1.895s
// E10	   668KB   20.02s 
// E11     904KB   205.2s

//PARALLEL SEGMENTED SIEVE
//	n		RAM	    Time
// E07	   203MB   0.481s
// E08	   202MB   4.405s 
// E09	      
// E10	      
// E11      

//Stats logged via Visual Studio Performance Profiler on i7 4790K @4.00GHz w/ 16GB DDR3 RAM and GTX 1070Ti
//Can't take n>

//Driver function
int main(int argc, char* argv[])
{
	//Range: Data-type dependent
	integer n; 
	printf("Enter n: "); 
	scanf("%llu", &n);

	integer m = sqrt(n);
	integer marklen = n >> 1;

	bool smallsieve = false;	//Use serial sieve for n<2^32
	if (n <= pow2_32)
		smallsieve = true;
	else if (n % pow2_32 > 0)	//If n>2^32 then round n to nearest multiple of 2^32
	{
		printf("Rounded %llu to ", n);
		n = ((n / pow2_32) + 1) * pow2_32;
		printf("%llu\n\n", n);
		m = 65536;				//sqrt(pow2_32)
		marklen = pow2_32 >> 1;
	}

	integer limit = (smallsieve) ? n : pow2_32;

	integer plen = trimSize(pow2_32);
	if (~n & 1) n--;
	if (~m & 1) m--;
	
	//Boolean array initialized to false
	bool *mark = (bool *)calloc(marklen + 1, sizeof(bool));	//Represents [2,3,5,7,9,11,...,sqrt(n)]

	//Array to store primes b/w [2,m]
	integer *P = (integer *)calloc(plen + 1, (size_t)size);
	if (mark == NULL || P == NULL) { printf("Memory Allocation Failed!\n"); exit(1); }
	integer i, j, k, offset;

	//Log execution time
	clock_t START_TIME, END_TIME;
	double  CPU_TIME = 0.0;
	float GPU_TIME = 0.0;
	float temp_t;

	//Setup-Phase: Calculate all primes in the range [3,m]
	START_TIME = clock();
	for (i = 5, k = 1, offset = 2; i < m; i += offset, offset = 6 - offset)	//i->[3,5,7,9...,sqrt(n)] | i corresponds to mark[(i-3)/2]
	{
		if (!mark[i >> 1])
		{
			if (i*i <= limit)
				for (j = i * i; j <= limit; j += (i << 1))	//j->[i^2,n] | increments by 2*i
					mark[j >> 1] = 1;
			P[k++] = i;
		}
	}
	END_TIME = clock();
	CPU_TIME = ((double)(END_TIME - START_TIME)) / CLOCKS_PER_SEC;
	
	printf("Stopped primary sieve at prime %llu\n", P[k - 1]);
	for (;i <= limit;i += offset, offset = 6 - offset)
	{
		if(!mark[i >> 1])
			P[k++] = i;
	}

	P[0] = 3;
	plen = k;
	free(mark);	
	printf("Last prime: %llu @ index [%llu]\n\n", P[plen - 1], plen - 1);
	if (smallsieve) goto end;

	integer chunksize = pow2_32 >> 1;						//Elements per chunk of 2^32 digits
	integer chunkcount = (n - pow2_32 - 1) / chunksize;		//No. of chunks
	integer completed = 1;
	printf("%llu chunk(s) for [%llu->%llu]\n", chunkcount, pow2_32 - 1, n);

	integer *d_P;

	//CUDA Malloc
	cudaMalloc(&d_P, (plen + 1) * (size));

	//Calculate dimensions
	dim3 TPB(threads);

	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	cudaMemcpy(d_P, P, plen * size, cudaMemcpyHostToDevice);

	while (completed <= chunkcount)
	{
		cudaEventRecord(start);
		SieveBlock<<<1, TPB >>> (d_P, completed);		//Execute sieving kernel
		cudaEventRecord(stop);
		cudaEventSynchronize(stop);
		cudaEventElapsedTime(&temp_t, start, stop);
		GPU_TIME += temp_t;
		completed++;
	}

	free(P); 
	cudaFree(d_P);

	GPU_TIME /= 1000;
end:printf("\nSETUP-PHASE CPU Time: %0.3f seconds\n", CPU_TIME);
	printf("COMPUTE-PHASE GPU Time: %0.3f seconds\n", GPU_TIME);
	//printf("FILE_WRITE CPU Time: %0.3f seconds\n", F_CPU_TIME);
	return 0;

}

