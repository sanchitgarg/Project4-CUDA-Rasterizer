/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya
 * @date      2012-2015
 * @copyright University of Pennsylvania & STUDENT
 */

#include "rasterize.h"

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <util/checkCUDAError.h>
#include "rasterizeTools.h"

//#include "sceneStructs.h"
#include "Scene.h"

extern Scene *scene;

#define SHOW_TIMING 0

struct keep
{
	__host__ __device__ bool operator()(const Triangle t)
	{
		return (!t.keep);
	}
};

static int width = 0;
static int height = 0;
static int *dev_bufIdx = NULL;
static VertexIn *dev_bufVertex = NULL;
static Triangle *dev_primitives = NULL;
static Edge *dev_edges = NULL;
static Fragment *dev_depthbuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;
static int bufIdxSize = 0;
static int vertCount = 0;
static glm::mat4 matrix;
static glm::vec3 camDir;
static Light light;
static Camera cam;

//Things added
static VertexOut *dev_outVertex = NULL;

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

// Writes fragment colors to the framebuffer
__global__
void render(int w, int h, Fragment *depthbuffer, glm::vec3 *framebuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        framebuffer[index] = depthbuffer[index].color;
    }
}

//Kernel function to figure out vertex in transformes space and NDC
__global__
void kernVertexShader(int numVertices, int w, int h, VertexIn * inVertex, VertexOut *outVertex, Camera cam)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if(index < numVertices)
	{
		glm::vec4 outPoint = glm::vec4(inVertex[index].pos.x, inVertex[index].pos.y, inVertex[index].pos.z, 1.0f);

		outVertex[index].transformedPos = multiplyMV(cam.model, outPoint);
		outPoint = cam.cameraMatrix * outPoint;

		if(outPoint.w != 0)
			outPoint /= outPoint.w;

		//In NDC
//		outVertex[index].pos = glm::vec3(outPoint);

		//In Device Coordinates
		outVertex[index].pos.x = outPoint.x * w;
		outVertex[index].pos.y = outPoint.y * h;
		outVertex[index].pos.z = outPoint.z;

		outVertex[index].nor = multiplyMV(cam.inverseTransposeModel, glm::vec4(inVertex[index].nor, 0.0f));

		//		outVertex[index].col = glm::vec3(0,0,1);
//		outVertex[index].nor = inVertex[index].nor;

//		printf ("InVertex : %f %f \nOutVertex : %f %f \n\n", inVertex[index].pos.x, inVertex[index].pos.y, outVertex[index].pos.x, outVertex[index].pos.y);
	}
}

//Kernel function to assemble triangles
__global__
void kernPrimitiveAssembly(int numTriangles, VertexOut *outVertex, VertexIn *inVertex, Triangle *triangles, int* indices, glm::vec3 camDir, bool backFaceCulling)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if(index < numTriangles)
	{
		int k_3 = 3 * index;

		Triangle &t = triangles[index];

		//Find the triangle normal
		glm::vec3 triNor = (outVertex[k_3].nor + outVertex[k_3+1].nor + outVertex[k_3+2].nor);

//		printf ("Tri Normal : %f %f %f\n", triNor.x, triNor.y, triNor.z);
//		printf ("Cam Dir : %f %f %f\n", camDir.x, camDir.y, camDir.z);

		if(backFaceCulling && glm::dot(triNor, camDir) > 0.0f)
		{
			//Triangle facing away from the camera
			//	Mark for deletion
			t.keep = false;
		}

		else
		{
			//Else save it
			t.keep = true;

			t.vOut[0] = outVertex[indices[k_3]];
			t.vOut[1] = outVertex[indices[k_3+1]];
			t.vOut[2] = outVertex[indices[k_3+2]];

			t.vIn[0] = inVertex[indices[k_3]];
			t.vIn[1] = inVertex[indices[k_3+1]];
			t.vIn[2] = inVertex[indices[k_3+2]];
		}
	}
}

//Kernel function to assemble edges
__global__
void kernEdgeAssembly(int numTriangles, VertexOut *outVertex, Edge *edge, int* indices)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if(index < numTriangles)
	{
		int k_3 = 3 * index;

		edge[indices[k_3]].v1 = outVertex[k_3].pos;
		edge[indices[k_3]].v2 = outVertex[k_3+1].pos;

		edge[indices[k_3+1]].v1 = outVertex[k_3+1].pos;
		edge[indices[k_3+1]].v2 = outVertex[k_3+2].pos;

		edge[indices[k_3+2]].v1 = outVertex[k_3+2].pos;
		edge[indices[k_3+2]].v2 = outVertex[k_3].pos;
	}
}

//Kernel function to draw axis
__global__
void kernDrawAxis(int w, int h, Fragment *fragments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
    {
		int index = x + (y * w);
		if((x - w*0.5f) == 0)
	    {
			fragments[index].color = glm::vec3(0, 1, 0);
	    }
	    else if((y - h*0.5f) == 0)
		{
			fragments[index].color = glm::vec3(1, 0, 0);
		}
	    else if(x == 0 || x == w-1)
		{
			fragments[index].color = glm::vec3(1);
		}
		else if(y == 0 || y == h)
		{
			fragments[index].color = glm::vec3(1);
		}
    }
}

//Kernel function to clear the depth and color buffer
__global__
void kernClearFragmentBuffer(int w, int h, Fragment *fragments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
    {
		int index = x + (y * w);

		Fragment &f = fragments[index];
		glm::vec3  ZERO(0.0f);

		f.color = ZERO;

		f.depth[0] = INT_MAX;
		f.depth[1] = INT_MAX;
		f.depth[2] = INT_MAX;
		f.depth[3] = INT_MAX;

		f.c[0] = ZERO;
		f.c[1] = ZERO;
		f.c[2] = ZERO;
		f.c[3] = ZERO;

		f.primitiveCol[0] = ZERO;
		f.primitiveCol[1] = ZERO;
		f.primitiveCol[2] = ZERO;
		f.primitiveCol[3] = ZERO;

		f.primitiveNor[0] = ZERO;
		f.primitiveNor[1] = ZERO;
		f.primitiveNor[2] = ZERO;
		f.primitiveNor[3] = ZERO;

		f.primitivePos[0] = ZERO;
		f.primitivePos[1] = ZERO;
		f.primitivePos[2] = ZERO;
		f.primitivePos[3] = ZERO;
    }
}

//Kernel function to rasterize the triangle
__global__
void kernRasterizeTraingles(int w, int h, Fragment *fragments, Triangle *triangles, int numTriangles, Camera cam, bool antiAliasing)
{
	//Rasterization per triangle
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if(index < numTriangles)
	{
		Triangle &t = triangles[index];

		glm::vec3 tri[3];
		tri[0] = t.vOut[0].pos;
		tri[1] = t.vOut[1].pos;
		tri[2] = t.vOut[2].pos;

		AABB aabb = getAABBForTriangle(tri);
		glm::ivec3 min, max;

		//Attempted clipping
		min.x = glm::clamp(aabb.min.x, -(float)w*0.5f+1, (float)w*0.5f-1);
		min.y = glm::clamp(aabb.min.y, -(float)h*0.5f+1, (float)h*0.5f-1);
		max.x = glm::clamp(aabb.max.x, -(float)w*0.5f+1, (float)w*0.5f-1);
		max.y = glm::clamp(aabb.max.y, -(float)h*0.5f+1, (float)h*0.5f-1);

		for(int i=min.x-1; i<=max.x+1; ++i)
		{
			for(int j=min.y-1; j<=max.y+1; ++j)
			{
				glm::vec2 point[4];
				int iterCount;
				if(antiAliasing)
				{
					point[0] = glm::vec2(float(i) - 0.25f, float(j) - 0.25f);
					point[1] = glm::vec2(float(i) - 0.25f, float(j) + 0.25f);
					point[2] = glm::vec2(float(i) + 0.25f, float(j) - 0.25f);
					point[3] = glm::vec2(float(i) + 0.25f, float(j) + 0.25f);
					iterCount = 4;
				}
				else
				{
					point[0] = glm::ivec2(i,j);
					iterCount = 1;
				}

				for(int k=0; k<iterCount; ++k)
				{
					glm::vec3 barycentric = calculateBarycentricCoordinate(tri, point[k]);

					if(isBarycentricCoordInBounds(barycentric))
					{
						glm::vec3 triIn[3];
						VertexIn tvIn[3] = {t.vIn[0], t.vIn[1], t.vIn[2]};

						triIn[0] = t.vOut[0].transformedPos;
						triIn[1] = t.vOut[1].transformedPos;
						triIn[2] = t.vOut[2].transformedPos;

						int fragIndex = int((i+w*0.5) + (j + h*0.5)*w);
						int depth = getZAtCoordinate(barycentric, triIn) * 10000;

						//Depth testing
						if(depth < fragments[fragIndex].depth[k])
						{
							atomicMin(&fragments[fragIndex].depth[k], depth);

							Fragment &f = fragments[fragIndex];
							//Fragment shading data
							f.primitiveNor[k] = barycentric.x * t.vOut[0].nor +
												barycentric.y * t.vOut[1].nor +
												barycentric.z * t.vOut[2].nor;

							f.primitivePos[k] = barycentric.x * t.vOut[0].transformedPos +
												barycentric.y * t.vOut[1].transformedPos +
												barycentric.z * t.vOut[2].transformedPos;

							f.primitiveCol[k] = barycentric.x * tvIn[0].col +
												barycentric.y * tvIn[1].col +
												barycentric.z * tvIn[2].col;
						}
					}
				}
			}
		}
	}
}


__global__
void kernFragmentShader(int w, int h, Fragment * fragment, Light light1, Light light2, bool antiAliasing)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int fragIndex = x + (y * w);

	if (x < w && y < h)
	{
		Fragment & f = fragment[fragIndex];

		if((f.depth[0] < INT_MAX) || (f.depth[1] < INT_MAX) || (f.depth[2] < INT_MAX) || (f.depth[3] < INT_MAX))
		{
			if(!antiAliasing)
			{
				f.color = calculateFragColor(f.primitiveNor[0], f.primitivePos[0], f.primitiveCol[0], light1, light2);
			}

			else
			{
				f.color = 0.25f * (calculateFragColor(f.primitiveNor[0], f.primitivePos[0], f.primitiveCol[0], light1, light2) +
									calculateFragColor(f.primitiveNor[1], f.primitivePos[1], f.primitiveCol[1], light1, light2) +
									calculateFragColor(f.primitiveNor[2], f.primitivePos[2], f.primitiveCol[2], light1, light2) +
									calculateFragColor(f.primitiveNor[3], f.primitivePos[3], f.primitiveCol[3], light1, light2)
									);
			}
		}
	}
}

//Kernel function to rasterize points
__global__
void kernRasterizePoints(int numVertices, int w, int h, Fragment *fragments, VertexOut * vertices, Camera cam, Light light1, Light light2)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if(index < numVertices)
	{
		glm::ivec2 point(vertices[index].pos.x, vertices[index].pos.y);

		//If point within bounds
		if(point.x > -w*0.5
				&& point.x < w*0.5f
				&& point.y > -h*0.5f
				&& point.y < h*0.5f )
		{
			//Color the corresponding fragment
			fragments[int((point.x + w*0.5f) + (point.y + h*0.5f)*w)].color = glm::vec3(1.0f);
		}
	}
}

//Kernel function to rasterize lines
__global__
void kernRasterizeLines(int numVertices, int w, int h, Fragment *fragments, Edge *edge, Camera cam, Light light1, Light light2)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if(index < numVertices)
	{
		Edge &e = edge[index];

		glm::vec2 v1(e.v1.x, e.v1.y);
		glm::vec2 v2(e.v2.x, e.v2.y);

		//Clamp edge to screen boundaries
		v1.x = glm::clamp(v1.x, -(float)w*0.5f, (float)w*0.5f);
		v1.y = glm::clamp(v1.y, -(float)h*0.5f, (float)h*0.5f);
		v2.x = glm::clamp(v2.x, -(float)w*0.5f, (float)w*0.5f);
		v2.y = glm::clamp(v2.y, -(float)h*0.5f, (float)h*0.5f);

		float m = (v2.y - v1.y) / (v2.x - v1.x);

		int inc;

		if(m > 1)
		{
			if(v1.y > v2.y)
			{
				inc = -1;
			}
			else
			{
				inc = 1;
			}

			int i, j;

			for(j=v1.y; j!=(int)v2.y; j += inc)
			{
				i = ((float)j - v1.y) / m + v1.x;
				fragments[int((i + w*0.5f) + (j + h*0.5f)*w)].color = glm::vec3(1.0f);
			}
		}

		else
		{
			if(v1.x > v2.x)
			{
				inc = -1;
			}

			else
			{
				inc = 1;
			}

			int i, j;

			for(i=v1.x; i!=(int)v2.x; i += inc)
			{
				j = m * ((float)i - v1.x) + v1.y;
				fragments[int((i + w*0.5f) + (j + h*0.5f)*w)].color = glm::vec3(1.0f);
			}
		}
	}
}

__global__
void kernAntiAliasing(int numTriangles, int w, int h, Fragment * fragment, Triangle * triangles)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < numTriangles)
	{
		Triangle &t = triangles[index];

		glm::vec3 tri[3];
		tri[0] = t.vOut[0].pos;
		tri[1] = t.vOut[1].pos;
		tri[2] = t.vOut[2].pos;

		AABB aabb = getAABBForTriangle(tri);
		glm::ivec3 min, max;

		//Attempted clipping
		min.x = glm::clamp(aabb.min.x, -(float)w*0.5f+2, (float)w*0.5f-2);
		min.y = glm::clamp(aabb.min.y, -(float)h*0.5f+2, (float)h*0.5f-2);
		max.x = glm::clamp(aabb.max.x, -(float)w*0.5f+2, (float)w*0.5f-2);
		max.y = glm::clamp(aabb.max.y, -(float)h*0.5f+2, (float)h*0.5f-2);

		for(int i=min.x-1; i<=max.x+1; ++i)
		{
			for(int j=min.y-1; j<=max.y+1; ++j)
			{
				int fragIndex = int((i+w*0.5) + (j + h*0.5)*w);
				int fragIndex0 = int((i+1 + w*0.5) + (j+1 + h*0.5)*w);
				int fragIndex1 = int((i+1 + w*0.5) + (j-1 + h*0.5)*w);
				int fragIndex2 = int((i-1 + w*0.5) + (j+1 + h*0.5)*w);
				int fragIndex3 = int((i-1 + w*0.5) + (j-1 + h*0.5)*w);
				int fragIndex4 = int((i+1 + w*0.5) + (j + h*0.5)*w);
				int fragIndex5 = int((i-1 + w*0.5) + (j + h*0.5)*w);
				int fragIndex6 = int((i + w*0.5) + (j+1 + h*0.5)*w);
				int fragIndex7 = int((i + w*0.5) + (j-1 + h*0.5)*w);

				fragment[fragIndex].color = 0.25f * fragment[fragIndex].color +
											0.125f * (fragment[fragIndex4].color+
													fragment[fragIndex5].color+
													fragment[fragIndex6].color+
													fragment[fragIndex7].color) +
											0.0625f* (fragment[fragIndex0].color+
													fragment[fragIndex1].color+
													fragment[fragIndex2].color+
													fragment[fragIndex3].color);
			}
		}
	}
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;

    cudaFree(dev_depthbuffer);
    cudaMalloc(&dev_depthbuffer,   width * height * sizeof(Fragment));
    cudaMemset(dev_depthbuffer, 0, width * height * sizeof(Fragment));

    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));

    checkCUDAError("rasterizeInit");
}

/**
 * Set all of the buffers necessary for rasterization.
 */

void rasterizeSetBuffers(
        int _bufIdxSize, int *bufIdx,
        int _vertCount, float *bufPos, float *bufNor, float *bufCol) {
    bufIdxSize = _bufIdxSize;
    vertCount = _vertCount;

    cudaFree(dev_bufIdx);
    cudaMalloc(&dev_bufIdx, bufIdxSize * sizeof(int));
    cudaMemcpy(dev_bufIdx, bufIdx, bufIdxSize * sizeof(int), cudaMemcpyHostToDevice);

    VertexIn *bufVertex = new VertexIn[_vertCount];
    for (int i = 0; i < vertCount; i++) {
        int j = i * 3;
        bufVertex[i].pos = glm::vec3(bufPos[j + 0], bufPos[j + 1], bufPos[j + 2]);
        bufVertex[i].nor = glm::vec3(bufNor[j + 0], bufNor[j + 1], bufNor[j + 2]);
        bufVertex[i].col = glm::vec3(bufCol[j + 0], bufCol[j + 1], bufCol[j + 2]);
    }

    cudaFree(dev_bufVertex);
    cudaMalloc(&dev_bufVertex, vertCount * sizeof(VertexIn));
    cudaMemcpy(dev_bufVertex, bufVertex, vertCount * sizeof(VertexIn), cudaMemcpyHostToDevice);

    cudaFree(dev_primitives);
    cudaMalloc(&dev_primitives, vertCount / 3 * sizeof(Triangle));
    cudaMemset(dev_primitives, 0, vertCount / 3 * sizeof(Triangle));

    cudaFree(dev_outVertex);
    cudaMalloc((void**)&dev_outVertex, vertCount * sizeof(VertexOut));

    cudaFree(dev_edges);
    cudaMalloc((void**)&dev_edges, vertCount * sizeof(Edge));

    checkCUDAError("rasterizeSetBuffers");
}

/**
 * Perform rasterization.
 */

void rasterize(uchar4 *pbo) {
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
                      (height - 1) / blockSize2d.y + 1);

    if(scene->run)
    {
    	int numThreads = 128;
		int numBlocks;
		int numTriangles = vertCount/3;
		scene->run = false;

		Camera &cam = scene->cam;
		Light &light1 = scene->light1;
		Light &light2 = scene->light2;

		//Clear the color and depth buffers
		kernClearFragmentBuffer<<<blockCount2d, blockSize2d>>>(width, height, dev_depthbuffer);

		//Drawing axis
		kernDrawAxis<<<blockCount2d, blockSize2d>>>(width, height, dev_depthbuffer);

		switch (scene->renderMode)
    	{
			case TRIANGLES:
			{
				cudaEvent_t startAll, stopAll;
				cudaEventCreate(&startAll);
				cudaEventCreate(&stopAll);

				cudaEventRecord(startAll);

				Triangle *dev_primitivesEnd;

				cudaEvent_t start, stop;
				cudaEventCreate(&start);
				cudaEventCreate(&stop);


				//------------------------------Vertex Shading------------------------------------
				cudaEventRecord(start);

					//Do vertex shading
					numBlocks = (vertCount + numThreads -1)/numThreads;
					kernVertexShader<<<numBlocks, numThreads>>>(vertCount, width, height, dev_bufVertex, dev_outVertex, cam);

				cudaEventRecord(stop);
				cudaEventSynchronize(stop);
				float milliseconds = 0;
				cudaEventElapsedTime(&milliseconds, start, stop);
				if(SHOW_TIMING)
					std::cout<<"Time Vertex Shading: "<<milliseconds<<std::endl;
				//--------------------------------------------------------------------------------------------


				//-----------------------------Primitive Assembly-------------------------------------------
				cudaEventRecord(start);

					//Do primitive (triangle) assembly
					numBlocks = (numTriangles + numThreads -1)/numThreads;
					kernPrimitiveAssembly<<<numBlocks, numThreads>>>(numTriangles, dev_outVertex, dev_bufVertex, dev_primitives, dev_bufIdx, cam.dir, scene->backFaceCulling);

				cudaEventRecord(stop);
				cudaEventSynchronize(stop);
				milliseconds = 0;
				cudaEventElapsedTime(&milliseconds, start, stop);
				if(SHOW_TIMING)
					std::cout<<"Time Primitive Assembly: "<<milliseconds<<std::endl;
				//--------------------------------------------------------------------------------------------

				if(scene->backFaceCulling)
				{
					//Back face culling
					dev_primitivesEnd = dev_primitives + numTriangles;
					dev_primitivesEnd = thrust::remove_if(thrust::device, dev_primitives, dev_primitivesEnd, keep());
					numTriangles = dev_primitivesEnd - dev_primitives;
				}


				//--------------------------------Rasterization---------------------------------------
				cudaEventRecord(start);

					//Rasterization per triangle
					numBlocks = (numTriangles + numThreads -1)/numThreads;
					kernRasterizeTraingles<<<numBlocks, numThreads>>>(width, height, dev_depthbuffer, dev_primitives, numTriangles, cam, scene->antiAliasing);

				cudaEventRecord(stop);
				cudaEventSynchronize(stop);
				milliseconds = 0;
				cudaEventElapsedTime(&milliseconds, start, stop);
				if(SHOW_TIMING)
					std::cout<<"Time Rasterize Triangle: "<<milliseconds<<std::endl;
				//--------------------------------------------------------------------------------------------


				//------------------------------------Fragment Shading----------------------------------------
				cudaEventRecord(start);

					kernFragmentShader<<<blockCount2d, blockSize2d>>>(width, height, dev_depthbuffer, light1, light2, scene->antiAliasing);

				cudaEventRecord(stop);
				cudaEventSynchronize(stop);
				milliseconds = 0;
				cudaEventElapsedTime(&milliseconds, start, stop);
				if(SHOW_TIMING)
					std::cout<<"Time Fragment Shader: "<<milliseconds<<std::endl;
				//--------------------------------------------------------------------------------------------


//				if(scene->antiAliasing)
//				{
//					kernAntiAliasing<<<numBlocks, numThreads>>>(numTriangles, width, height, dev_depthbuffer, dev_primitives);
//				}


				cudaEventRecord(stopAll);
				cudaEventSynchronize(stopAll);
				milliseconds = 0;
				cudaEventElapsedTime(&milliseconds, startAll, stopAll);
				if(SHOW_TIMING)
					std::cout<<"Time All: "<<milliseconds<<std::endl;

				std::cout<<std::endl;

				break;
			}

			case POINTS:
			{
				//Do vertex shading
				numBlocks = (vertCount + numThreads -1)/numThreads;
				kernVertexShader<<<numBlocks, numThreads>>>(vertCount, width, height, dev_bufVertex, dev_outVertex, cam);

				//Rasterization per vertex
				kernRasterizePoints<<<numBlocks, numThreads>>>(vertCount, width, height, dev_depthbuffer, dev_outVertex, cam, light1, light2);

				break;
			}

			case LINES:
			{
				//Do vertex shading
				numBlocks = (vertCount + numThreads -1)/numThreads;
				kernVertexShader<<<numBlocks, numThreads>>>(vertCount, width, height, dev_bufVertex, dev_outVertex, cam);

				//Do primitive (edge) assembly
				numBlocks = (numTriangles + numThreads -1)/numThreads;
				kernEdgeAssembly<<<numBlocks, numThreads>>>(numTriangles, dev_outVertex, dev_edges, dev_bufIdx);

				//Rasterization per edge
				numBlocks = (vertCount + numThreads -1)/numThreads;
				kernRasterizeLines<<<numBlocks, numThreads>>>(vertCount, width, height, dev_depthbuffer, dev_edges, cam, light1, light2);

				break;
			}
    	}
    }

    // Copy depthbuffer colors into framebuffer
    render<<<blockCount2d, blockSize2d>>>(width, height, dev_depthbuffer, dev_framebuffer);
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);

    //Save image data to write to file
    cudaMemcpy(scene->imageColor, dev_framebuffer, width*height*sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("rasterize");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {
    cudaFree(dev_bufIdx);
    dev_bufIdx = NULL;

    cudaFree(dev_bufVertex);
    dev_bufVertex = NULL;

    cudaFree(dev_primitives);
    dev_primitives = NULL;

    cudaFree(dev_depthbuffer);
    dev_depthbuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

    cudaFree(dev_outVertex);
    dev_outVertex = NULL;

    cudaFree(dev_edges);
    dev_edges = NULL;

    checkCUDAError("rasterizeFree");
}

