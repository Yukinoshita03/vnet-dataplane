#pragma once

#include <cstdint>

struct DnsClientTcAttachPlan {
    std::uint32_t ingress_handle;
    std::uint32_t ingress_priority;
    std::uint32_t egress_handle;
    std::uint32_t egress_priority;
};

constexpr DnsClientTcAttachPlan dns_client_tc_attach_plan()
{
    return {
        1,
        1,
        1,
        1,
    };
}
