#include <net/if.h>
#include <unistd.h>

#include <fstream>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "dhcp_relay_control.hpp"

namespace {

bool write_text_file(const std::string &path, const std::string &contents)
{
    std::ofstream output(path);
    if (!output)
        return false;
    output << contents;
    return static_cast<bool>(output);
}

int check(bool condition, const std::string &message)
{
    if (!condition) {
        std::cerr << "not ok - " << message << "\n";
        return -1;
    }
    return 0;
}

} // namespace

int main()
{
    const char *relay_environment = getenv("DHCP_TEST_RELAY_IFNAME");
    const std::string client_ifname = "lo";
    const std::string relay_ifname = relay_environment && *relay_environment
                                          ? relay_environment
                                          : "enp3s0";
    if (!if_nametoindex(client_ifname.c_str()) ||
        !if_nametoindex(relay_ifname.c_str()) || client_ifname == relay_ifname) {
        std::cerr << "need lo and a distinct relay test interface\n";
        return 1;
    }

    const std::string base = "/tmp/dhcp-relay-control-test-" +
                             std::to_string(getpid());
    const std::string valid_path = base + ".valid";
    const std::string duplicate_path = base + ".duplicate";
    const std::string invalid_mac_path = base + ".mac";
    const std::string invalid_lease_path = base + ".lease";
    const std::string extra_path = base + ".extra";
    const std::string valid_line =
        client_ifname + " " + relay_ifname +
        " 192.0.2.1 192.0.2.2 fa:16:3e:aa:bb:cc fa:16:3e:dd:ee:ff 30\n";

    if (check(write_text_file(valid_path, "# client relay policy\n" + valid_line),
              "write valid policy") != 0)
        return 1;
    std::vector<DhcpRelayPolicySpec> policies;
    std::string error;
    if (check(parse_dhcp_relay_policy_file(valid_path, &policies, &error) &&
                  policies.size() == 1 && policies[0].client_ifname == client_ifname &&
                  policies[0].relay_ifname == relay_ifname &&
                  policies[0].lease_seconds == 30,
              "parse valid DHCP relay policy: " + error) != 0)
        return 1;

    if (check(write_text_file(duplicate_path, valid_line + valid_line),
              "write duplicate policy") != 0)
        return 1;
    policies.clear();
    error.clear();
    if (check(!parse_dhcp_relay_policy_file(duplicate_path, &policies, &error) &&
                  error.find("duplicate DHCP relay client interface") !=
                      std::string::npos,
              "reject duplicate client interface") != 0)
        return 1;

    if (check(write_text_file(invalid_mac_path,
                              client_ifname + " " + relay_ifname +
                                  " 192.0.2.1 192.0.2.2 "
                                  "ff:ff:ff:ff:ff:ff "
                                  "fa:16:3e:dd:ee:ff 30\n"),
              "write invalid MAC policy") != 0)
        return 1;
    policies.clear();
    error.clear();
    if (check(!parse_dhcp_relay_policy_file(invalid_mac_path, &policies, &error),
              "reject multicast MAC") != 0)
        return 1;

    if (check(write_text_file(invalid_lease_path,
                              client_ifname + " " + relay_ifname +
                                  " 192.0.2.1 192.0.2.2 "
                                  "fa:16:3e:aa:bb:cc "
                                  "fa:16:3e:dd:ee:ff 0\n"),
              "write invalid lease policy") != 0)
        return 1;
    policies.clear();
    error.clear();
    if (check(!parse_dhcp_relay_policy_file(invalid_lease_path, &policies, &error),
              "reject zero lease") != 0)
        return 1;

    if (check(write_text_file(extra_path, valid_line.substr(0, valid_line.size() - 1) +
                                  " extra\n"),
              "write extra-field policy") != 0)
        return 1;
    policies.clear();
    error.clear();
    if (check(!parse_dhcp_relay_policy_file(extra_path, &policies, &error),
              "reject extra field") != 0)
        return 1;

    unlink(valid_path.c_str());
    unlink(duplicate_path.c_str());
    unlink(invalid_mac_path.c_str());
    unlink(invalid_lease_path.c_str());
    unlink(extra_path.c_str());
    std::cout << "DHCP relay control tests passed\n";
    return 0;
}
