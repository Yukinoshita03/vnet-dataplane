#pragma once

#include "dynamic_cache_controller.hpp"

#include <string>
#include <vector>

class BpfCachePolicyPublisher final : public CachePolicyPublisher {
public:
    explicit BpfCachePolicyPublisher(std::vector<std::string> map_paths);

    bool publish(CacheMode mode, uint64_t epoch,
                 std::string *error) override;

private:
    std::vector<std::string> map_paths_;
};
