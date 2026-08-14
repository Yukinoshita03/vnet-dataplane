#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <signal.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

namespace {

constexpr size_t kMaxDnsNameLength = 256;

volatile sig_atomic_t exiting = 0;

struct DnsQuery {
    uint16_t record_type;
    uint16_t record_class;
    char name[kMaxDnsNameLength];
};

struct ARecord {
    in_addr address;
    uint32_t ttl;
};

struct Options {
    std::string ifname;
    std::string bpf_object;
    std::string cache_file;
    std::string xdp_mode = "generic";
};

void handle_signal(int)
{
    exiting = 1;
}

void usage(const char *program)
{
    std::cerr << "Usage: " << program
              << " --dev IFNAME --bpf-object FILE --cache-file FILE"
              << " [--xdp-mode generic|native]\n";
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--dev" && i + 1 < argc) {
            options->ifname = argv[++i];
        } else if (argument == "--bpf-object" && i + 1 < argc) {
            options->bpf_object = argv[++i];
        } else if (argument == "--cache-file" && i + 1 < argc) {
            options->cache_file = argv[++i];
        } else if (argument == "--xdp-mode" && i + 1 < argc) {
            options->xdp_mode = argv[++i];
            if (options->xdp_mode != "generic" &&
                options->xdp_mode != "native")
                return false;
        } else {
            return false;
        }
    }
    return !options->ifname.empty() && !options->bpf_object.empty() &&
           !options->cache_file.empty();
}

bool encode_qname(const std::string &domain, char *output, std::string *error)
{
    std::memset(output, 0, kMaxDnsNameLength);
    std::string name = domain;
    if (!name.empty() && name.back() == '.')
        name.pop_back();
    if (name.empty()) {
        *error = "empty DNS name";
        return false;
    }

    size_t output_offset = 0;
    size_t label_start = 0;
    while (label_start < name.size()) {
        const size_t dot = name.find('.', label_start);
        const size_t label_end = dot == std::string::npos ? name.size() : dot;
        const size_t label_length = label_end - label_start;
        if (!label_length || label_length > 63 ||
            output_offset + label_length + 2 > kMaxDnsNameLength) {
            *error = "invalid DNS name: " + domain;
            return false;
        }
        output[output_offset++] = static_cast<char>(label_length);
        for (size_t i = label_start; i < label_end; ++i) {
            char character = name[i];
            if (character >= 'A' && character <= 'Z')
                character += 'a' - 'A';
            output[output_offset++] = character;
        }
        if (dot == std::string::npos)
            break;
        label_start = dot + 1;
    }
    output[output_offset] = 0;
    return true;
}

bool install_cache(int map_fd, const std::string &path, uint64_t *installed,
                   uint64_t *skipped, std::string *error)
{
    std::ifstream input(path);
    if (!input) {
        *error = "failed to open cache file: " + path;
        return false;
    }

    std::string line;
    unsigned int line_number = 0;
    while (std::getline(input, line)) {
        ++line_number;
        const size_t comment = line.find('#');
        if (comment != std::string::npos)
            line.resize(comment);
        std::istringstream fields(line);
        std::string domain;
        std::string type;
        std::string value;
        std::string ttl_text;
        std::string extra;
        if (!(fields >> domain))
            continue;
        if (!(fields >> type >> value >> ttl_text) || fields >> extra) {
            *error = "invalid cache file line " +
                     std::to_string(line_number);
            return false;
        }
        if (type != "A") {
            ++*skipped;
            continue;
        }

        char *ttl_end = nullptr;
        errno = 0;
        const unsigned long parsed_ttl =
            std::strtoul(ttl_text.c_str(), &ttl_end, 10);
        if (errno || !ttl_end || *ttl_end != '\0' || !parsed_ttl ||
            parsed_ttl > UINT32_MAX) {
            *error = "invalid TTL on cache file line " +
                     std::to_string(line_number);
            return false;
        }

        DnsQuery key = {};
        key.record_type = 1;
        key.record_class = 1;
        if (!encode_qname(domain, key.name, error))
            return false;
        ARecord record = {};
        if (inet_pton(AF_INET, value.c_str(), &record.address) != 1) {
            *error = "invalid IPv4 address on cache file line " +
                     std::to_string(line_number);
            return false;
        }
        record.ttl = static_cast<uint32_t>(parsed_ttl);
        if (bpf_map_update_elem(map_fd, &key, &record, BPF_ANY) != 0) {
            *error = "failed to update Xpress DNS map on line " +
                     std::to_string(line_number) + ": " +
                     std::strerror(errno);
            return false;
        }
        ++*installed;
    }
    if (!*installed) {
        *error = "cache file contains no A records";
        return false;
    }
    return true;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        usage(argv[0]);
        return 2;
    }

    const unsigned int ifindex = if_nametoindex(options.ifname.c_str());
    if (!ifindex) {
        std::cerr << "interface does not exist: " << options.ifname << "\n";
        return 2;
    }

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    bpf_object *object =
        bpf_object__open_file(options.bpf_object.c_str(), nullptr);
    if (!object) {
        std::cerr << "failed to open BPF object: " << options.bpf_object
                  << "\n";
        return 1;
    }
    bpf_program *program =
        bpf_object__find_program_by_name(object, "xdp_dns");
    bpf_map *records =
        bpf_object__find_map_by_name(object, "xdns_a_records");
    if (!program || !records) {
        std::cerr << "Xpress DNS object is missing xdp_dns or xdns_a_records\n";
        bpf_object__close(object);
        return 1;
    }
    bpf_program__set_type(program, BPF_PROG_TYPE_XDP);
    int error = bpf_object__load(object);
    if (error) {
        std::cerr << "failed to load Xpress DNS object: "
                  << std::strerror(-error) << "\n";
        bpf_object__close(object);
        return 1;
    }

    uint64_t installed = 0;
    uint64_t skipped = 0;
    std::string cache_error;
    if (!install_cache(bpf_map__fd(records), options.cache_file, &installed,
                       &skipped, &cache_error)) {
        std::cerr << cache_error << "\n";
        bpf_object__close(object);
        return 1;
    }

    const int program_fd = bpf_program__fd(program);
    const uint32_t mode_flags = options.xdp_mode == "generic"
                                    ? XDP_FLAGS_SKB_MODE
                                    : XDP_FLAGS_DRV_MODE;
    error = bpf_xdp_attach(static_cast<int>(ifindex), program_fd,
                           mode_flags | XDP_FLAGS_UPDATE_IF_NOEXIST, nullptr);
    if (error) {
        std::cerr << "failed to attach Xpress DNS on " << options.ifname
                  << ": " << std::strerror(-error) << "\n";
        bpf_object__close(object);
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    std::cout << "xpress_dns attached dev=" << options.ifname
              << " mode=" << options.xdp_mode << " installed_a=" << installed
              << " skipped_non_a=" << skipped << std::endl;
    while (!exiting)
        pause();

    bpf_xdp_attach_opts detach_options = {};
    detach_options.sz = sizeof(detach_options);
    detach_options.old_prog_fd = program_fd;
    error = bpf_xdp_detach(static_cast<int>(ifindex), mode_flags,
                           &detach_options);
    if (error)
        std::cerr << "owner-checked Xpress DNS detach failed: "
                  << std::strerror(-error) << "\n";
    else
        std::cout << "xpress_dns detached" << std::endl;
    bpf_object__close(object);
    return error ? 1 : 0;
}
