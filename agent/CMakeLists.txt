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

if(VNET_BUILD_TESTS)
  add_test(NAME vnet_agent_help COMMAND vnet-agent --help)
  add_test(NAME vnet_agent_status COMMAND vnet-agent status)

  add_test(NAME vnet_agent_unknown_command COMMAND vnet-agent unknown)
  set_tests_properties(vnet_agent_unknown_command PROPERTIES WILL_FAIL TRUE)

  add_test(NAME vnet_agent_missing_bench_name COMMAND vnet-agent bench)
  set_tests_properties(vnet_agent_missing_bench_name PROPERTIES WILL_FAIL TRUE)

  if(WIN32)
    add_test(NAME vnet_agent_probe_windows_only COMMAND vnet-agent probe)
    set_tests_properties(vnet_agent_probe_windows_only PROPERTIES WILL_FAIL TRUE)
  endif()
endif()
