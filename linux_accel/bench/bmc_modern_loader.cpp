#include <errno.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {

volatile sig_atomic_t exiting = 0;

struct ProgramSpec {
    const char *name;
    bpf_prog_type type;
    int tail_index;
    const char *tail_map;
};

constexpr ProgramSpec kPrograms[] = {
    {"bmc_rx_filter_main", BPF_PROG_TYPE_XDP, -1, nullptr},
    {"bmc_hash_keys_main", BPF_PROG_TYPE_XDP, 0, "map_progs_xdp"},
    {"bmc_prepare_packet_main", BPF_PROG_TYPE_XDP, 1, "map_progs_xdp"},
    {"bmc_write_reply_main", BPF_PROG_TYPE_XDP, 2, "map_progs_xdp"},
    {"bmc_invalidate_cache_main", BPF_PROG_TYPE_XDP, 3, "map_progs_xdp"},
    {"bmc_tx_filter_main", BPF_PROG_TYPE_SCHED_CLS, -1, nullptr},
    {"bmc_update_cache_main", BPF_PROG_TYPE_SCHED_CLS, 0, "map_progs_tc"},
};

void handle_signal(int)
{
    exiting = 1;
}

void usage(const char *program)
{
    std::cerr << "Usage: " << program
              << " --dev IFNAME --bpf-object FILE"
              << " [--xdp-mode generic|native]\n";
}

struct Options {
    std::string ifname;
    std::string bpf_object;
    std::string xdp_mode = "generic";
};

struct TcAttachment {
    bpf_tc_hook hook = {};
    bpf_tc_opts options = {};
    bool attached = false;
    bool created_qdisc = false;
};

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        std::string argument = argv[i];
        if (argument == "--dev" && i + 1 < argc)
            options->ifname = argv[++i];
        else if (argument == "--bpf-object" && i + 1 < argc)
            options->bpf_object = argv[++i];
        else if (argument == "--xdp-mode" && i + 1 < argc)
            options->xdp_mode = argv[++i];
        else
            return false;
    }
    return !options->ifname.empty() && !options->bpf_object.empty() &&
           (options->xdp_mode == "generic" || options->xdp_mode == "native");
}

bool install_tail_calls(bpf_object *object)
{
    for (const ProgramSpec &spec : kPrograms) {
        if (spec.tail_index < 0)
            continue;
        bpf_program *program = bpf_object__find_program_by_name(object, spec.name);
        bpf_map *map = bpf_object__find_map_by_name(object, spec.tail_map);
        if (!program || !map) {
            std::cerr << "BMC object is missing " << spec.name << " or "
                      << spec.tail_map << "\n";
            return false;
        }
        uint32_t key = static_cast<uint32_t>(spec.tail_index);
        int program_fd = bpf_program__fd(program);
        if (bpf_map_update_elem(bpf_map__fd(map), &key, &program_fd,
                                BPF_ANY) != 0) {
            std::cerr << "failed to install BMC tail call " << spec.name
                      << ": " << strerror(errno) << "\n";
            return false;
        }
    }
    return true;
}

uint64_t read_percpu_field(int map_fd, size_t field)
{
    int cpus = libbpf_num_possible_cpus();
    if (cpus <= 0)
        return 0;
    std::vector<uint32_t> values(static_cast<size_t>(cpus) * 8);
    uint32_t key = 0;
    if (bpf_map_lookup_elem(map_fd, &key, values.data()) != 0)
        return 0;
    uint64_t total = 0;
    for (int cpu = 0; cpu < cpus; ++cpu)
        total += values[static_cast<size_t>(cpu) * 8 + field];
    return total;
}

void print_stats(int map_fd)
{
    static const char *names[] = {
        "get_recv", "set_recv", "get_resp", "hit_misprediction",
        "hit", "miss", "update", "invalidation",
    };
    std::cout << "bmc_stats";
    for (size_t field = 0; field < 8; ++field)
        std::cout << ' ' << names[field] << '=' << read_percpu_field(map_fd, field);
    std::cout << std::endl;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        usage(argv[0]);
        return 2;
    }
    unsigned int ifindex = if_nametoindex(options.ifname.c_str());
    if (!ifindex) {
        std::cerr << "interface does not exist: " << options.ifname << "\n";
        return 2;
    }

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    bpf_object *object = bpf_object__open_file(options.bpf_object.c_str(), nullptr);
    if (!object) {
        std::cerr << "failed to open BMC object\n";
        return 1;
    }
    for (const ProgramSpec &spec : kPrograms) {
        bpf_program *program = bpf_object__find_program_by_name(object, spec.name);
        if (!program) {
            std::cerr << "BMC object is missing program " << spec.name << "\n";
            bpf_object__close(object);
            return 1;
        }
        bpf_program__set_type(program, spec.type);
    }
    int error = bpf_object__load(object);
    if (error) {
        std::cerr << "failed to load BMC object: " << strerror(-error) << "\n";
        bpf_object__close(object);
        return 1;
    }
    if (!install_tail_calls(object)) {
        bpf_object__close(object);
        return 1;
    }

    bpf_program *main_program =
        bpf_object__find_program_by_name(object, "bmc_rx_filter_main");
    bpf_program *tc_program =
        bpf_object__find_program_by_name(object, "bmc_tx_filter_main");
    bpf_map *stats = bpf_object__find_map_by_name(object, "map_stats");
    int program_fd = bpf_program__fd(main_program);
    int mode_flags = options.xdp_mode == "generic" ? XDP_FLAGS_SKB_MODE
                                                    : XDP_FLAGS_DRV_MODE;
    error = bpf_xdp_attach(static_cast<int>(ifindex), program_fd,
                           mode_flags | XDP_FLAGS_UPDATE_IF_NOEXIST, nullptr);
    if (error) {
        std::cerr << "failed to attach BMC: " << strerror(-error) << "\n";
        bpf_object__close(object);
        return 1;
    }

    TcAttachment tc;
    tc.hook.sz = sizeof(tc.hook);
    tc.hook.ifindex = static_cast<int>(ifindex);
    tc.hook.attach_point = BPF_TC_EGRESS;
    error = bpf_tc_hook_create(&tc.hook);
    if (error == 0) {
        tc.created_qdisc = true;
    } else if (error != -EEXIST) {
        std::cerr << "failed to create clsact for BMC: "
                  << strerror(-error) << "\n";
        bpf_xdp_detach(static_cast<int>(ifindex), mode_flags, nullptr);
        bpf_object__close(object);
        return 1;
    }
    tc.options.sz = sizeof(tc.options);
    tc.options.prog_fd = bpf_program__fd(tc_program);
    tc.options.handle = 0xB0C;
    tc.options.priority = 0xB0C;
    error = bpf_tc_attach(&tc.hook, &tc.options);
    if (error) {
        std::cerr << "failed to attach BMC TC egress learner: "
                  << strerror(-error) << "\n";
        if (tc.created_qdisc)
            bpf_tc_hook_destroy(&tc.hook);
        bpf_xdp_detach(static_cast<int>(ifindex), mode_flags, nullptr);
        bpf_object__close(object);
        return 1;
    }
    tc.attached = true;

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    std::cout << "bmc attached dev=" << options.ifname
              << " mode=" << options.xdp_mode << std::endl;
    while (!exiting)
        pause();

    print_stats(bpf_map__fd(stats));
    if (tc.attached) {
        bpf_tc_opts detach_options = {};
        detach_options.sz = sizeof(detach_options);
        detach_options.handle = tc.options.handle;
        detach_options.priority = tc.options.priority;
        error = bpf_tc_detach(&tc.hook, &detach_options);
        if (error && error != -ENOENT)
            std::cerr << "owner-scoped BMC TC detach failed: "
                      << strerror(-error) << "\n";
    }
    if (tc.created_qdisc) {
        int destroy_error = bpf_tc_hook_destroy(&tc.hook);
        if (destroy_error && destroy_error != -ENOENT)
            std::cerr << "BMC clsact cleanup failed: "
                      << strerror(-destroy_error) << "\n";
    }
    bpf_xdp_attach_opts detach = {};
    detach.sz = sizeof(detach);
    detach.old_prog_fd = program_fd;
    int xdp_error =
        bpf_xdp_detach(static_cast<int>(ifindex), mode_flags, &detach);
    if (xdp_error)
        std::cerr << "owner-checked BMC detach failed: " << strerror(-xdp_error)
                  << "\n";
    bpf_object__close(object);
    return (error || xdp_error) ? 1 : 0;
}
