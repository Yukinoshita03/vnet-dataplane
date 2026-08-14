#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_ether.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <fstream>
#include <iostream>
#include <memory>
#include <cstdlib>
#include <string>
#include <vector>

#include "arp_proxy_control.hpp"

namespace {

int check(bool condition, const std::string &message)
{
    if (!condition) {
        std::cerr << "not ok - " << message << "\n";
        return -1;
    }
    return 0;
}

std::string interface_name(const char *environment_name,
                           const char *default_name)
{
    const char *value = getenv(environment_name);
    if (value && *value)
        return value;
    return default_name;
}

std::string distinct_interface_name(const char *environment_name,
                                    const std::string &excluded_name)
{
    const char *value = getenv(environment_name);
    if (value && *value)
        return value;

    struct if_nameindex *interfaces = if_nameindex();
    if (!interfaces)
        return {};
    std::string selected;
    for (const struct if_nameindex *candidate = interfaces;
         candidate->if_index != 0 && candidate->if_name != nullptr; ++candidate) {
        if (candidate->if_name != excluded_name) {
            selected = candidate->if_name;
            break;
        }
    }
    if_freenameindex(interfaces);
    return selected;
}

bool write_text_file(const std::string &path, const std::string &contents)
{
    std::ofstream output(path);
    if (!output)
        return false;
    output << contents;
    return static_cast<bool>(output);
}

bool parse_ipv4(const char *text, __be32 *address)
{
    return inet_pton(AF_INET, text, address) == 1;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <bpf_object>\n";
        return 2;
    }

    std::string tap_a = interface_name("ARP_TEST_IFNAME_A", "lo");
    std::string tap_b =
        distinct_interface_name("ARP_TEST_IFNAME_B", tap_a);
    if (!if_nametoindex(tap_a.c_str()) || !if_nametoindex(tap_b.c_str()) ||
        tap_a == tap_b) {
        std::cerr << "need two distinct test interfaces for control test\n";
        return 1;
    }

    const std::string policy_path =
        "/tmp/arp-proxy-control-test-" + std::to_string(getpid()) + ".conf";
    const std::string valid_policy =
        "# tap target_ipv4 target_mac lease_seconds\n" + tap_a +
        " 10.0.0.1 fa:16:3e:aa:bb:cc 30\n" + tap_a +
        " 10.0.0.2 fa:16:3e:dd:ee:ff 30\n" + tap_b +
        " 10.0.0.1 fa:16:3e:11:22:33 30\n";
    if (check(write_text_file(policy_path, valid_policy),
              "write valid ARP policy") != 0)
        return 1;

    std::vector<TapArpPolicy> policies;
    std::string error;
    if (check(parse_arp_policy_file(policy_path, &policies, &error),
              "parse valid multi-tap policy: " + error) != 0)
        return 1;
    if (check(policies.size() == 2 && policies[0].bindings.size() == 2 &&
                  policies[1].bindings.size() == 1,
              "group policy rows by tap and preserve multiple targets") != 0)
        return 1;

    const std::string duplicate_path = policy_path + ".duplicate";
    if (check(write_text_file(duplicate_path,
                              tap_a + " 10.0.0.1 fa:16:3e:aa:bb:cc 30\n" +
                                  tap_a + " 10.0.0.1 fa:16:3e:dd:ee:ff 30\n"),
              "write duplicate policy") != 0)
        return 1;
    policies.clear();
    error.clear();
    if (check(!parse_arp_policy_file(duplicate_path, &policies, &error) &&
                  error.find("duplicate ARP target") != std::string::npos,
              "reject duplicate tap/target keys") != 0)
        return 1;

    const std::string invalid_path = policy_path + ".invalid";
    if (check(write_text_file(invalid_path,
                              tap_a + " 10.0.0.1 ff:ff:ff:ff:ff:ff 30\n"),
              "write invalid policy") != 0)
        return 1;
    policies.clear();
    error.clear();
    if (check(!parse_arp_policy_file(invalid_path, &policies, &error) &&
                  error.find("invalid ARP target MAC") != std::string::npos,
              "reject multicast/broadcast target MAC") != 0)
        return 1;

    bpf_object *object = bpf_object__open_file(argv[1], nullptr);
    if (check(object != nullptr, "open BPF object") != 0)
        return 1;
    bpf_program *program =
        bpf_object__find_program_by_name(object, "dns_xdp_monitor");
    if (check(program != nullptr, "find server XDP program") != 0) {
        bpf_object__close(object);
        return 1;
    }
    bpf_program__set_type(program, BPF_PROG_TYPE_XDP);
    int load_error = bpf_object__load(object);
    if (check(load_error == 0, "load BPF object: " +
                               std::string(strerror(-load_error))) != 0) {
        bpf_object__close(object);
        return 1;
    }

    std::string invalid_policy_error;
    TapArpPolicy invalid_policy = {tap_a, {{"10.0.0.1", "00:00:00:00:00:00", 30}}};
    if (check(!ArpProxyControl::Create(object, {invalid_policy},
                                       &invalid_policy_error),
              "invalid policy cannot create control plane") != 0) {
        bpf_object__close(object);
        return 1;
    }

    error.clear();
    std::unique_ptr<ArpProxyControl> control;
    // Reparse after the negative parser cases above.
    policies.clear();
    if (check(parse_arp_policy_file(policy_path, &policies, &error),
              "reparse valid policy before map test") != 0) {
        bpf_object__close(object);
        return 1;
    }
    control = ArpProxyControl::Create(object, policies, &error);
    if (check(control != nullptr, "create ARP control and install maps: " + error) !=
        0) {
        bpf_object__close(object);
        return 1;
    }
    if (check(control->ifindices().size() == 2,
              "control exposes all attached tap ifindices") != 0)
        return 1;

    bpf_map *tap_map = bpf_object__find_map_by_name(object, "arp_tap_states");
    bpf_map *binding_map = bpf_object__find_map_by_name(object, "arp_bindings");
    if (check(tap_map && binding_map, "find installed ARP maps") != 0)
        return 1;
    arp_tap_key tap_key = {};
    tap_key.ifindex = if_nametoindex(tap_a.c_str());
    arp_tap_state tap_state = {};
    if (check(bpf_map_lookup_elem(bpf_map__fd(tap_map), &tap_key, &tap_state) == 0 &&
                  tap_state.flags == ARP_TAP_ENABLED && tap_state.generation == 1,
              "initial tap policy is enabled at generation one") != 0)
        return 1;

    arp_binding_key binding_key = {};
    binding_key.ifindex = tap_key.ifindex;
    if (check(parse_ipv4("10.0.0.1", &binding_key.target_ipv4),
              "parse binding lookup target") != 0)
        return 1;
    arp_binding_value binding_value = {};
    if (check(bpf_map_lookup_elem(bpf_map__fd(binding_map), &binding_key,
                                  &binding_value) == 0 &&
                  binding_value.generation == 1 &&
                  binding_value.target_mac[0] == 0xfa &&
                  binding_value.target_mac[3] == 0xaa,
              "initial target binding is installed") != 0)
        return 1;

    TapArpPolicy replacement = {tap_a,
                                {{"10.0.0.1", "fa:16:3e:00:00:01", 30}}};
    if (check(control->ReplaceTapPolicy(replacement, &error),
              "activate replacement generation: " + error) != 0)
        return 1;
    tap_state = {};
    binding_value = {};
    if (check(bpf_map_lookup_elem(bpf_map__fd(tap_map), &tap_key, &tap_state) == 0 &&
                  tap_state.generation == 2 &&
                  bpf_map_lookup_elem(bpf_map__fd(binding_map), &binding_key,
                                      &binding_value) == 0 &&
                  binding_value.generation == 2 &&
                  binding_value.target_mac[5] == 1,
              "replacement switches tap and binding atomically by generation") != 0)
        return 1;

    if (check(control->RenewAll(&error), "renew all tap leases: " + error) != 0)
        return 1;

    std::vector<unsigned int> added_ifindices;
    std::vector<unsigned int> removed_ifindices;
    if (check(control->Reconcile({replacement}, &added_ifindices,
                                 &removed_ifindices, &error),
              "remove one tap through reconcile: " + error) != 0)
        return 1;
    if (check(added_ifindices.empty() && removed_ifindices.size() == 1 &&
                  removed_ifindices[0] == if_nametoindex(tap_b.c_str()),
              "reconcile reports the removed tap ifindex") != 0)
        return 1;

    TapArpPolicy tap_b_policy = {
        tap_b, {{"10.0.0.1", "fa:16:3e:11:22:44", 30}}};
    added_ifindices.clear();
    removed_ifindices.clear();
    if (check(control->Reconcile({replacement, tap_b_policy},
                                 &added_ifindices, &removed_ifindices, &error),
              "add tap through reconcile: " + error) != 0)
        return 1;
    if (check(added_ifindices.size() == 1 &&
                  added_ifindices[0] == if_nametoindex(tap_b.c_str()) &&
                  removed_ifindices.empty(),
              "reconcile reports the added tap ifindex") != 0)
        return 1;

    control.reset();
    tap_state = {};
    if (check(bpf_map_lookup_elem(bpf_map__fd(tap_map), &tap_key, &tap_state) == 0 &&
                  !(tap_state.flags & ARP_TAP_ENABLED),
              "control destructor disables every tap") != 0)
        return 1;

    unlink(policy_path.c_str());
    unlink(duplicate_path.c_str());
    unlink(invalid_path.c_str());
    bpf_object__close(object);
    std::cout << "ARP proxy control tests passed\n";
    return 0;
}
