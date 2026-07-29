#include "dns_tc_attach_plan.hpp"
#include "grpc_tc_attach_plan.hpp"

#include <cstdint>
#include <iostream>

namespace {

constexpr std::uint32_t kNetMigIngressHandle = 0x65;
constexpr std::uint32_t kNetMigEgressHandle = 0x66;
constexpr std::uint32_t kNetMigPriority = 1;

} // namespace

int main()
{
    constexpr DnsClientTcAttachPlan dns = dns_client_tc_attach_plan();
    constexpr GrpcTcAttachPlan grpc = grpc_tc_attach_plan();

    if (dns.ingress_priority != kNetMigPriority ||
        grpc.ingress_priority != kNetMigPriority ||
        dns.ingress_handle == grpc.ingress_handle ||
        dns.ingress_handle == kNetMigIngressHandle ||
        grpc.ingress_handle == kNetMigIngressHandle) {
        std::cerr << "ingress observers need distinct slots in the NetMig "
                     "priority chain\n";
        return 1;
    }
    if (dns.egress_priority != kNetMigPriority ||
        grpc.egress_priority != kNetMigPriority ||
        dns.egress_handle == grpc.egress_handle ||
        dns.egress_handle == kNetMigEgressHandle ||
        grpc.egress_handle == kNetMigEgressHandle) {
        std::cerr << "egress observers need distinct slots in the NetMig "
                     "priority chain\n";
        return 1;
    }
    if (dns.ingress_handle != dns.egress_handle ||
        dns.ingress_priority != dns.egress_priority ||
        grpc.ingress_handle != grpc.egress_handle ||
        grpc.ingress_priority != grpc.egress_priority) {
        std::cerr << "each observer must use the same deterministic slot on "
                     "the independent ingress and egress chains\n";
        return 1;
    }

    return 0;
}
