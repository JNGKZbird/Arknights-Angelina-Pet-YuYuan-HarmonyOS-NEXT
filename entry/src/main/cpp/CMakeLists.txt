# spine38 C++ 光栅化内核（NAPI 探针阶段）
cmake_minimum_required(VERSION 3.5.0)
project(raster)

add_library(raster SHARED raster.cpp)
target_link_libraries(raster PUBLIC libace_napi.z.so libace_ndk.z.so libnative_window.so libhilog_ndk.z.so libqos.so libEGL.so libGLESv3.so)
