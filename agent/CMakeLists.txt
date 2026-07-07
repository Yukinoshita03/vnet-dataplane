add_executable(vnet-agent
  src/main.cpp
)

target_compile_features(vnet-agent PRIVATE cxx_std_20)

target_compile_definitions(vnet-agent
  PRIVATE
    VNET_AGENT_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
)

target_include_directories(vnet-agent
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
