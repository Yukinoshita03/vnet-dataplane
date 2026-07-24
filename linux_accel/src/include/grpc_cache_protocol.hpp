#pragma once

#include "grpc_cache_types.hpp"

#include <cstdint>
#include <vector>

std::vector<uint8_t> build_grpc_health_response(uint32_t stream_id,
                                                HealthStatus status);

bool send_all(int fd, const std::vector<uint8_t> &data);
bool send_server_settings(int fd);
bool read_request_stream(int fd, RequestInfo *info,
                         std::vector<uint8_t> *raw_request);
