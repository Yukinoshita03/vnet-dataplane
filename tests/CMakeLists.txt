add_executable(packet_test
  packet_test.cpp
)

target_link_libraries(packet_test PRIVATE vnet_core)

add_test(NAME packet_test COMMAND packet_test)
