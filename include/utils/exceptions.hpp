#pragma once

#ifndef EXCEPTIONS_H_
#define EXCEPTIONS_H_

#include <fstream>
#include <stdexcept>
#include <string>
#include <sstream>
#include <iostream>
#include <execinfo.h>
#include "dedisp.h"
#include "cuda.h"
#include "cuda_runtime.h"
#include "cufft.h"

class ErrorChecker {
public:

  static int check_pthread_create_error(int pthread_return_value, std::string function_name){

	  if(pthread_return_value == EXIT_SUCCESS ) return EXIT_SUCCESS;

	  std::stringstream  error_message;
	  error_message << function_name << " ";
	  switch(pthread_return_value){

	  case EAGAIN:
		  error_message << "The system lacked the necessary resources to create another thread, "
		  			  "or the system-imposed limit on the total number of threads "
		  			  "in a process PTHREAD_THREADS_MAX would be exceeded.";
		  break;
	  case EINVAL:
		  error_message << "the attr value to pthread_create is invalid. ";
		  break;
	  case EPERM:
		  error_message << "The caller does not have appropriate permission to set "
				  "the required scheduling parameters or scheduling policy.";
		  break;

	  }

	  std::cerr << " Pthread failed with error no:"  << pthread_return_value << " and error message: "
			  << error_message.str()<< std::endl;

	  return EXIT_FAILURE;


  }

  static void check_dedisp_error(dedisp_error error,
			    std::string function_name)
  {
    if (error != DEDISP_NO_ERROR) {
      std::stringstream error_msg;
      error_msg << function_name 
		<< " failed with DEDISP error: "
		<< dedisp_get_error_string(error) 
		<< std::endl;
      throw std::runtime_error(error_msg.str());
    }
  }
  
  static void check_file_error(std::ifstream& infile, std::string filename){
    if(!infile.good()) {
      std::stringstream error_msg;
      error_msg << "File "<< filename << " could not be opened: ";
      
      if ( (infile.rdstate() & std::ifstream::failbit ) != 0 )
	error_msg << "Logical error on i/o operation" << std::endl;

      if ( (infile.rdstate() & std::ifstream::badbit ) != 0 )
	error_msg << "Read/writing error on i/o operation" << std::endl;

      if ( (infile.rdstate() & std::ifstream::eofbit ) != 0 )
	error_msg << "End-of-File reached on input operation" << std::endl;

      throw std::runtime_error(error_msg.str());
    }
  }

  static void check_file_error(std::ofstream& infile, std::string filename){
    if(!infile.good()) {
      std::stringstream error_msg;
      error_msg << "File "<< filename << " could not be opened: ";

      if ( (infile.rdstate() & std::ifstream::failbit ) != 0 )
        error_msg << "Logical error on i/o operation" << std::endl;

      if ( (infile.rdstate() & std::ifstream::badbit ) != 0 )
        error_msg << "Read/writing error on i/o operation" << std::endl;

      if ( (infile.rdstate() & std::ifstream::eofbit ) != 0 )
        error_msg << "End-of-File reached on input operation" << std::endl;

      throw std::runtime_error(error_msg.str());
    }
  }

  static void check_cuda_error(std::string msg="Unspecified location"){
    cudaDeviceSynchronize();
    cudaError_t error = cudaGetLastError();
    if (error!=cudaSuccess){
      std::stringstream error_msg;
      error_msg << "CUDA failed with error: "
                << cudaGetErrorString(error) << std::endl 
		<< "Additional: " << msg << std::endl;
      throw std::runtime_error(error_msg.str());
    }
  }

  /*
  static void check_cuda_error(cudaError_t error){
    check_cuda_error(error,"");
  }
  */

  static void throw_error(std::string msg){
    throw std::runtime_error(msg.c_str());
  }

  
  static void check_cufft_error(cufftResult error){
    if (error!=CUFFT_SUCCESS){
      std::stringstream error_msg;
      error_msg << "cuFFT failed with error: ";
      switch (error)
	{
	case CUFFT_INVALID_PLAN:
	  error_msg <<  "CUFFT_INVALID_PLAN";
	  break;

	case CUFFT_ALLOC_FAILED:
	  error_msg <<  "CUFFT_ALLOC_FAILED";
	  break;

	case CUFFT_INVALID_TYPE:
	  error_msg <<  "CUFFT_INVALID_TYPE";
	  break;

	case CUFFT_INVALID_VALUE:
	  error_msg <<  "CUFFT_INVALID_VALUE";
	  break;

	case CUFFT_INTERNAL_ERROR:
	  error_msg <<  "CUFFT_INTERNAL_ERROR";
	  break;

	case CUFFT_EXEC_FAILED:
	  error_msg <<  "CUFFT_EXEC_FAILED";
	  break;
	  
	case CUFFT_SETUP_FAILED:
	  error_msg <<  "CUFFT_SETUP_FAILED";
	  break;

	case CUFFT_INVALID_SIZE:
	  error_msg <<  "CUFFT_INVALID_SIZE";
	  break;

	case CUFFT_UNALIGNED_DATA:
	  error_msg <<  "CUFFT_UNALIGNED_DATA";
	  break;

	default:
	  error_msg <<  "<unknown>";
	}
      error_msg << std::endl;
      print_stack_trace(200);
      throw std::runtime_error(error_msg.str());
    }
  }

  static void print_stack_trace(unsigned int max_depth){
    int trace_depth;    
    void *buffer[max_depth];
    char **strings;

    trace_depth = backtrace(buffer, max_depth); 
    strings = backtrace_symbols(buffer, trace_depth);
    if (strings == NULL) {
      std::cerr << "Stack trace failed" << std::endl;
    } else {
      for (int jj = 0; jj < trace_depth; jj++)
	std::cerr << strings[jj] << std::endl;
      free(strings);
    }
  }
};


#endif /* EXCEPTIONS_H_ */
