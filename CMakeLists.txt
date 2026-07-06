cmake_minimum_required(VERSION 3.20)

project(vnet_dataplane VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(VNET_BUILD_TESTS "Build vnet-dataplane tests" ON)

add_subdirectory(userspace)

if(VNET_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
