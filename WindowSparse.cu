#define WINDOWSPARSE_THREADS 128
#define WINDOWSPARSE_STREAMS 8

__global__ void cunnx_WindowSparse_copyBiasOutput_kernel(
  float *output, const float** bias, int outputWindowSize)
{
  unsigned int k = blockIdx.x;
  const float *bias_k = bias[k];
  float *output_k = output + outputWindowSize*k;
  
  for (unsigned int i=threadIdx.x; i<outputWindowSize; i+=blockDim.x)
  {
    output_k[i] = bias_k[i];
  }
}

  
static int cunnx_WindowSparse_updateOutput(lua_State *L)
{ 
  /* input, inputIndice, outputIndice, inputScale, outputScale, gradOutput*/
  // batchSize x inputWindowSize x inputSize
  THCudaTensor *input = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");  
  // batchSize
  THLongTensor *inputIndice = (THLongTensor*)luaT_checkudata(L, 3, "torch.LongTensor");
  // batchSize x inputWindowSize
  THCudaTensor *inputScale = (THCudaTensor*)luaT_checkudata(L, 5, "torch.CudaTensor");
  // batchSize
  THLongTensor *outputIndice = (THLongTensor*)luaT_checkudata(L, 4, "torch.LongTensor");
  // batchSize x outputWindowSize
  THCudaTensor *outputScale = (THCudaTensor*)luaT_checkudata(L, 6, "torch.CudaTensor");
  
  int batchedGemmMax = luaT_getfieldcheckint(L, 1, "batchedGemmMax");
  int inputSize = luaT_getfieldcheckint(L, 1, "inputSize");
  int outputSize = luaT_getfieldcheckint(L, 1, "outputSize");
  int batchSize, inputWindowSize, outputWindowSize;
  
  // outputSize x inputSize
  THCudaTensor *weight = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
  // outputSize
  THCudaTensor *bias = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "bias", "torch.CudaTensor");
  // batchSize
  THCharTensor *biasHost = (THCharTensor*)luaT_getfieldcheckudata(L, 1, "inputHost", "torch.CharTensor");
  THCudaTensor *biasCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "inputCuda", "torch.CudaTensor");
  // batchSize x outputWindowSize
  THCudaTensor *output = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "output", "torch.CudaTensor");
  
  THCudaTensor* output_, *weight_, *_weight_, *bias_, *input_;
  
  cublasStatus_t stat;
  cublasHandle_t handle;
  
  float alpha = 1;
  float beta = 1;
  
  luaL_argcheck(L, input->nDimension == 2, 2, "2D(batch mode) tensor expected");
  luaL_argcheck(L, input->size[1] <= inputSize, 2, "invalid input size"); 
  luaL_argcheck(L, inputIndice->nDimension == 1, 3, "1D(batch mode) tensor expected");
  luaL_argcheck(L, outputIndice->nDimension == 1, 4, "1D(batch mode) tensor expected");
  luaL_argcheck(L, inputScale->nDimension == 2, 5, "2D(batch mode) tensor expected");
  luaL_argcheck(L, outputScale->nDimension == 2, 6, "2D(batch mode) tensor expected");
  
  batchSize = input->size[0];
  inputWindowSize = input->size[1];
  outputWindowSize = outputScale->size[1];
  
  THCudaTensor_resize2d(output, input->size[0], outputScale->size[1]);
    
  stat = cublasCreate(&handle);
  if (stat != CUBLAS_STATUS_SUCCESS) 
    THError("CUBLAS initialization failed");
    
  output_ = THCudaTensor_new();
  weight_ = THCudaTensor_new();
  _weight_ = THCudaTensor_new();
  bias_ = THCudaTensor_new();
  input_ = THCudaTensor_new();
  
  /* copy bias into output */
  THCharTensor_resize1d(biasHost, batchSize*sizeof(float*));
  THCudaTensor_resize1d(biasCuda, batchSize*sizeof(float*)/sizeof(float));
  
  const float **biasB = (const float **)THCharTensor_data(biasHost);
  const float **biasB_d = (const float **)THCudaTensor_data(biasCuda);
  
  for (int i=0; i<batchSize; i++)
  {
    int outputIdx = THLongTensor_get1d(outputIndice, i) - 1;
    THCudaTensor_narrow(bias_, bias, 0, outputIdx, outputWindowSize);
    biasB[i] = THCudaTensor_data(bias_);
  }
  
  if(cudaMemcpy(biasB_d, biasB, sizeof(float*) * batchSize, cudaMemcpyHostToDevice) != cudaSuccess)
    THError("cudaMemcpy failed");
  
  /* call cudakernel */
  dim3 blocks(batchSize); // each cuda-block is an example
  dim3 threads(WINDOWSPARSE_THREADS);
  cunnx_WindowSparse_copyBiasOutput_kernel<<<blocks,threads>>>(
    THCudaTensor_data(output), biasB_d, outputWindowSize
  );
  
  cudaError errcode = cudaGetLastError();
  if(errcode != cudaSuccess)
    THError(cudaGetErrorString(errcode));
  
  if (sqrt(inputWindowSize*outputWindowSize) > batchedGemmMax)
  {
    cudaStream_t streams[WINDOWSPARSE_STREAMS];
    
    for (int i=0; i<WINDOWSPARSE_STREAMS; i++)
    {
      if (cudaStreamCreate(&streams[i]) != cudaSuccess)
        THError("error initializing stream");
    }
    
    for (int i=0; i<batchSize; i++)
    {
      cublasSetStream(handle, streams[i%WINDOWSPARSE_STREAMS]);
      
      int inputIdx = THLongTensor_get1d(inputIndice, i) - 1;
      int outputIdx = THLongTensor_get1d(outputIndice, i) - 1;
      
      THCudaTensor_select(output_, output, 0, i);
      THCudaTensor_select(input_, input, 0, i);
      THCudaTensor_narrow(_weight_, weight, 1, inputIdx, inputWindowSize);
      THCudaTensor_narrow(weight_, _weight_, 0, outputIdx, outputWindowSize);
      
      stat = cublasSgemv(handle, CUBLAS_OP_T,  inputWindowSize, outputWindowSize,
                        &alpha, (const float*)THCudaTensor_data(weight_), inputSize,
                        (const float*)THCudaTensor_data(input_), 1,
                        &beta, THCudaTensor_data(output_), 1);
    }
    
    cublasSetStream(handle, NULL);
  
    for (int i=0; i<WINDOWSPARSE_STREAMS; i++)
    {
      if (cudaStreamDestroy(streams[i]) != cudaSuccess)
        THError("error destroying stream");
    }
  }
  else
  {  
    THCharTensor *inputHost = (THCharTensor*)luaT_getfieldcheckudata(L, 1, "inputHost", "torch.CharTensor");
    THCharTensor *weightHost = (THCharTensor*)luaT_getfieldcheckudata(L, 1, "weightHost", "torch.CharTensor");
    THCharTensor *outputHost = (THCharTensor*)luaT_getfieldcheckudata(L, 1, "outputHost", "torch.CharTensor");
    
    THCudaTensor *inputCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "inputCuda", "torch.CudaTensor");
    THCudaTensor *weightCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "weightCuda", "torch.CudaTensor");
    THCudaTensor *outputCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "outputCuda", "torch.CudaTensor");
    // put output back on top of the stack
    output = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "output", "torch.CudaTensor");
    
    cublasSetStream(handle, NULL);
    
    THCharTensor_resize1d(inputHost, batchSize*sizeof(float*));
    THCharTensor_resize1d(weightHost, batchSize*sizeof(float*));
    THCharTensor_resize1d(outputHost, batchSize*sizeof(float*));
    
    THCudaTensor_resize1d(inputCuda, batchSize*sizeof(float*)/sizeof(float));
    THCudaTensor_resize1d(weightCuda, batchSize*sizeof(float*)/sizeof(float));
    THCudaTensor_resize1d(outputCuda, batchSize*sizeof(float*)/sizeof(float));
    
    const float **inputB = (const float **)THCharTensor_data(inputHost);
    const float **weightB = (const float **)THCharTensor_data(weightHost);
    float **outputB = (float **)THCharTensor_data(outputHost);
    
    const float **inputB_d = (const float **)THCudaTensor_data(inputCuda);
    const float **weightB_d = (const float **)THCudaTensor_data(weightCuda);
    float **outputB_d = (float **)THCudaTensor_data(outputCuda);
    
    for (int i=0; i<batchSize; i++)
    {
      int inputIdx = THLongTensor_get1d(inputIndice, i) - 1;
      int outputIdx = THLongTensor_get1d(outputIndice, i) - 1;
      
      THCudaTensor_select(output_, output, 0, i);
      THCudaTensor_select(input_, input, 0, i);
      THCudaTensor_narrow(_weight_, weight, 1, inputIdx, inputWindowSize);
      THCudaTensor_narrow(weight_, _weight_, 0, outputIdx, outputWindowSize);
      
      inputB[i] = THCudaTensor_data(input_);
      weightB[i] = THCudaTensor_data(weight_);
      outputB[i] = THCudaTensor_data(output_);
    }
    
    if(cudaMemcpy(inputB_d, inputB, sizeof(float*) * batchSize, cudaMemcpyHostToDevice) != cudaSuccess)
      THError("cudaMemcpy failed");
    if(cudaMemcpy(weightB_d, weightB, sizeof(float*) * batchSize, cudaMemcpyHostToDevice) != cudaSuccess)
      THError("cudaMemcpy failed");
    if(cudaMemcpy(outputB_d, outputB, sizeof(float*) * batchSize, cudaMemcpyHostToDevice) != cudaSuccess)
      THError("cudaMemcpy failed");
    
                  
    stat = cublasSgemmBatched(handle, CUBLAS_OP_T, CUBLAS_OP_N,
                             outputWindowSize, 1, inputWindowSize,
                             &alpha, weightB_d, inputSize, 
                             inputB_d, inputWindowSize, 
                             &beta, outputB_d, outputWindowSize, 
                             batchSize);
    
    if (stat != CUBLAS_STATUS_SUCCESS) 
      THError("cublasSgemmBatched failed");
    
    
  }
  
  cublasDestroy(handle);
  THCublasCheck();  
  
  THCudaTensor_free(input_);
  THCudaTensor_free(weight_);
  THCudaTensor_free(_weight_);
  THCudaTensor_free(output_);
  THCudaTensor_free(bias_);

  return 1;
}



static int cunnx_WindowSparse_updateGradInput(lua_State *L)
{ 
  /* input, inputIndice, outputIndice, inputScale, outputScale, gradOutput*/
  THCudaTensor *input = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");  
  THLongTensor *inputIndice = (THLongTensor*)luaT_checkudata(L, 3, "torch.LongTensor");
  THCudaTensor *inputScale = (THCudaTensor*)luaT_checkudata(L, 5, "torch.CudaTensor");
  THLongTensor *outputIndice = (THLongTensor*)luaT_checkudata(L, 4, "torch.LongTensor");
  THCudaTensor *outputScale = (THCudaTensor*)luaT_checkudata(L, 6, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor*)luaT_checkudata(L, 7, "torch.CudaTensor");
  
  int batchedGemmMax = luaT_getfieldcheckint(L, 1, "batchedGemmMax");
  int inputSize = luaT_getfieldcheckint(L, 1, "inputSize");
  int outputSize = luaT_getfieldcheckint(L, 1, "outputSize");
  int batchSize, inputWindowSize, outputWindowSize;
  
  THCudaTensor *weight = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
  THCudaTensor *gradInput = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "_gradInput", "torch.CudaTensor");
  THCudaTensor* gradOutput_, *weight_, *_weight_, *gradInput_;
  
  cublasStatus_t stat;
  cublasHandle_t handle;
  
  float alpha = 1;
  float beta = 0;
  
  luaL_argcheck(L, input->nDimension == 2, 2, "2D(batch mode) tensor expected");
  luaL_argcheck(L, input->size[1] <= inputSize, 2, "invalid input size"); 
  luaL_argcheck(L, inputIndice->nDimension == 1, 3, "1D(batch mode) tensor expected");
  luaL_argcheck(L, outputIndice->nDimension == 1, 4, "1D(batch mode) tensor expected");
  luaL_argcheck(L, inputScale->nDimension == 2, 5, "2D(batch mode) tensor expected");
  luaL_argcheck(L, outputScale->nDimension == 2, 6, "2D(batch mode) tensor expected");
  
  THCudaTensor_resizeAs(gradInput, input); 
  
  batchSize = input->size[0];
  inputWindowSize = input->size[1];
  outputWindowSize = outputScale->size[1];
    
  stat = cublasCreate(&handle);
  if (stat != CUBLAS_STATUS_SUCCESS) 
    THError("CUBLAS initialization failed");
    
  gradOutput_ = THCudaTensor_new();
  weight_ = THCudaTensor_new();
  _weight_ = THCudaTensor_new();
  gradInput_ = THCudaTensor_new();
  

  if (sqrt(inputWindowSize*outputWindowSize) > batchedGemmMax)
  {
    cudaStream_t streams[WINDOWSPARSE_STREAMS];
    
    for (int i=0; i<WINDOWSPARSE_STREAMS; i++)
    {
      if (cudaStreamCreate(&streams[i]) != cudaSuccess)
        THError("error initializing stream");
    }
    
    for (int i=0; i<batchSize; i++)
    {
      cublasSetStream(handle, streams[i%WINDOWSPARSE_STREAMS]);
      
      int inputIdx = THLongTensor_get1d(inputIndice, i) - 1;
      int outputIdx = THLongTensor_get1d(outputIndice, i) - 1;
      
      THCudaTensor_select(gradOutput_, gradOutput, 0, i);
      THCudaTensor_select(gradInput_, gradInput, 0, i);
      THCudaTensor_narrow(_weight_, weight, 1, inputIdx, inputWindowSize);
      THCudaTensor_narrow(weight_, _weight_, 0, outputIdx, outputWindowSize);
      
      
      
      stat = cublasSgemv(handle, CUBLAS_OP_N,  outputWindowSize, inputWindowSize,
                        &alpha, (const float*)THCudaTensor_data(weight_), inputSize,
                        (const float*)THCudaTensor_data(gradOutput_), 1,
                        &beta, THCudaTensor_data(gradInput_), 1);
    }
    
    cublasSetStream(handle, NULL);
  
    for (int i=0; i<WINDOWSPARSE_STREAMS; i++)
    {
      if (cudaStreamDestroy(streams[i]) != cudaSuccess)
        THError("error destroying stream");
    }
  }
  else
  {  
    THCharTensor *inputHost = (THCharTensor*)luaT_getfieldcheckudata(L, 1, "inputHost", "torch.CharTensor");
    THCharTensor *weightHost = (THCharTensor*)luaT_getfieldcheckudata(L, 1, "weightHost", "torch.CharTensor");
    THCharTensor *outputHost = (THCharTensor*)luaT_getfieldcheckudata(L, 1, "outputHost", "torch.CharTensor");
    
    THCudaTensor *inputCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "inputCuda", "torch.CudaTensor");
    THCudaTensor *weightCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "weightCuda", "torch.CudaTensor");
    THCudaTensor *outputCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "outputCuda", "torch.CudaTensor");
    // put output back on top of the stack
    gradInput = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "_gradInput", "torch.CudaTensor");
    
    cublasSetStream(handle, NULL);
    
    THCharTensor_resize1d(inputHost, batchSize*sizeof(float*));
    THCharTensor_resize1d(weightHost, batchSize*sizeof(float*));
    THCharTensor_resize1d(outputHost, batchSize*sizeof(float*));
    
    THCudaTensor_resize1d(inputCuda, batchSize*sizeof(float*)/sizeof(float));
    THCudaTensor_resize1d(weightCuda, batchSize*sizeof(float*)/sizeof(float));
    THCudaTensor_resize1d(outputCuda, batchSize*sizeof(float*)/sizeof(float));
    
    float **gradInputB = (float **)THCharTensor_data(inputHost);
    const float **weightB = (const float **)THCharTensor_data(weightHost);
    const float **gradOutputB = (const float **)THCharTensor_data(outputHost);
    
    float **gradInputB_d = (float **)THCudaTensor_data(inputCuda);
    const float **weightB_d = (const float **)THCudaTensor_data(weightCuda);
    const float **gradOutputB_d = (const float **)THCudaTensor_data(outputCuda);
    
    for (int i=0; i<batchSize; i++)
    {
      int inputIdx = THLongTensor_get1d(inputIndice, i) - 1;
      int outputIdx = THLongTensor_get1d(outputIndice, i) - 1;
      
      THCudaTensor_select(gradOutput_, gradOutput, 0, i);
      THCudaTensor_select(gradInput_, gradInput, 0, i);
      THCudaTensor_narrow(_weight_, weight, 1, inputIdx, inputWindowSize);
      THCudaTensor_narrow(weight_, _weight_, 0, outputIdx, outputWindowSize);
      
      gradInputB[i] = THCudaTensor_data(gradInput_);
      weightB[i] = THCudaTensor_data(weight_);
      gradOutputB[i] = THCudaTensor_data(gradOutput_);
    }
    
    if(cudaMemcpy(gradInputB_d, gradInputB, sizeof(float*) * batchSize, cudaMemcpyHostToDevice) != cudaSuccess)
      THError("cudaMemcpy failed");
    if(cudaMemcpy(weightB_d, weightB, sizeof(float*) * batchSize, cudaMemcpyHostToDevice) != cudaSuccess)
      THError("cudaMemcpy failed");
    if(cudaMemcpy(gradOutputB_d, gradOutputB, sizeof(float*) * batchSize, cudaMemcpyHostToDevice) != cudaSuccess)
      THError("cudaMemcpy failed");
                  
    stat = cublasSgemmBatched(handle, CUBLAS_OP_N, CUBLAS_OP_N,
                             inputWindowSize, 1, outputWindowSize,
                             &alpha, weightB_d, inputSize, 
                             gradOutputB_d, outputWindowSize, 
                             &beta, gradInputB_d, inputWindowSize, 
                             batchSize);
    
    if (stat != CUBLAS_STATUS_SUCCESS) 
      THError("cublasSgemmBatched failed");
    
    
  }
  
  cublasDestroy(handle);
  THCublasCheck();  
  
  THCudaTensor_free(gradInput_);
  THCudaTensor_free(weight_);
  THCudaTensor_free(_weight_);
  THCudaTensor_free(gradOutput_);

  return 1;
}
  
__global__ void cunnx_WindowSparse_accGradParameters_kernel(
  float *gradWeight, float* gradBias, float *gradOutput, 
  float *input, float *inputIndice, float *outputIndice, 
  int inputWindowSize, int outputWindowSize, 
  int inputSize, int outputSize, float scale)
{
  __shared__ float buffer[WINDOWSPARSE_THREADS];
  int tx = threadIdx.x;
  int i_step = blockDim.x;
  int k = blockIdx.x;
  
  int inputIdx = (int)inputIndice[k] - 1;
  int outputIdx = (int)outputIndice[k] - 1;
  
  float *input_k = input + k*inputWindowSize;
  float *gradOutput_k = gradOutput + k*outputWindowSize;
  float *gradWeight_k = gradWeight + outputIdx*inputSize + inputIdx;
  float *gradBias_k = gradBias + outputIdx;

  // addr weights (scalar-products)
  for (int i=tx; i<inputWindowSize; i+=i_step)
  {
    // copy input to buffer
    buffer[tx] = input_k[i]*scale;
  
    // multiply accumulate weights
    for (int j=0; j<outputWindowSize; j++)
      atomicAdd(&(gradWeight_k[j*inputSize + i]), gradOutput_k[j]*buffer[tx]);
  }
  
  // cadd bias i.e. multiply accumulate biases
  for (int j=tx; j<outputWindowSize; j+=i_step)
    atomicAdd(&(gradBias_k[j]), gradOutput_k[j]*scale);
}


static int cunnx_WindowSparse_accGradParameters(lua_State *L)
{ 
  /* input, inputIndice, outputIndice, inputScale, outputScale, gradOutput, scale */
  THCudaTensor *input = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");  
  THLongTensor *inputIndice = (THLongTensor*)luaT_checkudata(L, 3, "torch.LongTensor");
  THCudaTensor *inputScale = (THCudaTensor*)luaT_checkudata(L, 5, "torch.CudaTensor");
  THLongTensor *outputIndice = (THLongTensor*)luaT_checkudata(L, 4, "torch.LongTensor");
  THCudaTensor *outputScale = (THCudaTensor*)luaT_checkudata(L, 6, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor*)luaT_checkudata(L, 7, "torch.CudaTensor");
  float scale = luaL_optnumber(L, 8, 1);
  
  int inputSize = luaT_getfieldcheckint(L, 1, "inputSize");
  int outputSize = luaT_getfieldcheckint(L, 1, "outputSize");
  int batchSize, inputWindowSize, outputWindowSize;
  
  // nOutputBlock x nInputBlock x outputSize x inputSize
  THCudaTensor *gradWeight = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "gradWeight", "torch.CudaTensor");
  THCudaTensor *gradBias = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "gradBias", "torch.CudaTensor");
  
  THCudaTensor *inputIndiceCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "inputIndiceCuda", "torch.CudaTensor");
  THCudaTensor *outputIndiceCuda = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "outputIndiceCuda", "torch.CudaTensor");

  luaL_argcheck(L, input->nDimension == 2, 2, "2D(batch mode) tensor expected");
  luaL_argcheck(L, input->size[1] <= inputSize, 2, "invalid input size"); 
  luaL_argcheck(L, inputIndice->nDimension == 1, 3, "1D(batch mode) tensor expected");
  luaL_argcheck(L, outputIndice->nDimension == 1, 4, "1D(batch mode) tensor expected");
  luaL_argcheck(L, inputScale->nDimension == 2, 5, "2D(batch mode) tensor expected");
  luaL_argcheck(L, outputScale->nDimension == 2, 6, "2D(batch mode) tensor expected");
  
  batchSize = input->size[0];
  inputWindowSize = input->size[1];
  outputWindowSize = outputScale->size[1];
  
  THCudaTensor_resize1d(inputIndiceCuda, batchSize);
  THCudaTensor_resize1d(outputIndiceCuda, batchSize);
  
  THCudaTensor_copyLong(inputIndiceCuda, inputIndice);
  THCudaTensor_copyLong(outputIndiceCuda, outputIndice);
  
  /* call cudakernel */
  dim3 blocks(batchSize); // each cuda-block is an example
  dim3 threads(WINDOWSPARSE_THREADS);
  cunnx_WindowSparse_accGradParameters_kernel<<<blocks,threads>>>(
    THCudaTensor_data(gradWeight), THCudaTensor_data(gradBias), 
    THCudaTensor_data(gradOutput), THCudaTensor_data(input),
    THCudaTensor_data(inputIndiceCuda), THCudaTensor_data(outputIndiceCuda), 
    inputWindowSize, outputWindowSize, inputSize, outputSize, scale
  );
  
  cudaError errcode = cudaGetLastError();
  if(errcode != cudaSuccess)
    THError(cudaGetErrorString(errcode));  

  return 0;
}  
  
static const struct luaL_Reg cunnx_WindowSparse__ [] = {
  {"WindowSparse_updateOutput", cunnx_WindowSparse_updateOutput},
  {"WindowSparse_updateGradInput", cunnx_WindowSparse_updateGradInput},
  {"WindowSparse_accGradParameters", cunnx_WindowSparse_accGradParameters},
  {NULL, NULL}
};

static void cunnx_WindowSparse_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.CudaTensor");
  luaT_registeratname(L, cunnx_WindowSparse__, "nn");
  lua_pop(L,1);
}
