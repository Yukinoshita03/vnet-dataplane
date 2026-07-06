add_library(vnet_core
  src/packet.cpp
)

target_include_directories(vnet_core
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_features(vnet_core PUBLIC cxx_std_20)

add_executable(vnetctl
  src/main.cpp
)

target_link_libraries(vnetctl PRIVATE vnet_core)
