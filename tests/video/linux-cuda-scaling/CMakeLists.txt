cmake_minimum_required(VERSION 3.24)
project(plank_cuda_scaling LANGUAGES CXX CUDA)

# Production CUDA conversion and colorspace code, without capture, NVENC,
# services, or changing the display. Build on Rocky; run on a qualified GPU.
get_filename_component(PLANK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(HOST "${PLANK_ROOT}/apps/host/linux")
set(PLANK_FFMPEG_INCLUDE "" CACHE PATH "Prepared Host FFmpeg headers")
if(NOT EXISTS "${PLANK_FFMPEG_INCLUDE}/libavutil/pixfmt.h")
  message(FATAL_ERROR "Point PLANK_FFMPEG_INCLUDE at the prepared Host FFmpeg include directory")
endif()
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_ARCHITECTURES all)
find_package(CUDAToolkit REQUIRED)
find_package(Boost REQUIRED COMPONENTS log thread filesystem)
add_executable(cuda-scaling
  scaling.cpp
  ../../input/linux-recovery/logging.cpp
  "${HOST}/src/platform/linux/cuda.cu"
  "${HOST}/src/video_colorspace.cpp")
target_include_directories(cuda-scaling PRIVATE "${HOST}" "${HOST}/third-party"
  "${HOST}/third-party/nvfbc" "${PLANK_FFMPEG_INCLUDE}")
target_compile_definitions(cuda-scaling PRIVATE SUNSHINE_BUILD_CUDA SUNSHINE_TESTS BOOST_LOG_DYN_LINK)
target_compile_options(cuda-scaling PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX>:-ffunction-sections;-fdata-sections>"
  "$<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=-ffunction-sections,-fdata-sections>")
set_source_files_properties(scaling.cpp PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra;-Werror")
target_link_options(cuda-scaling PRIVATE -Wl,--gc-sections -static-libstdc++ -static-libgcc)
target_link_libraries(cuda-scaling PRIVATE CUDA::cudart_static Boost::log Boost::thread Boost::filesystem)
enable_testing()
add_test(NAME cuda-scaling COMMAND cuda-scaling)
set_tests_properties(cuda-scaling PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 120)
