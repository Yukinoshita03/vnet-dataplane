#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <linux/if_link.h>
#include <linux/if_xdp.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <net/if.h>
#include <poll.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <xdp/xsk.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kFrameSize = 2048;
constexpr uint32_t kFrameCount = 4096;
constexpr uint32_t kBatchSize = 64;
constexpr uint16_t kServerPort = 9000;
constexpr std::array<uint8_t, 4> kRequest = {'p', 'i', 'n', 'g'};
constexpr std::array<uint8_t, 7> kResponse = {'p', 'o', 'n', 'g', '-', 'o', 'k'};

volatile sig_atomic_t exiting = 0;

struct Counters {
    uint64_t rx = 0;
    uint64_t hit = 0;
    uint64_t pass = 0;
    uint64_t tx = 0;
    uint64_t tx_full = 0;
    uint64_t invalid = 0;
};

void handle_signal(int)
{
    exiting = 1;
}

uint16_t ipv4_checksum(const iphdr *ip)
{
    const auto *words = reinterpret_cast<const uint16_t *>(ip);
    uint32_t sum = 0;
    for (size_t i = 0; i < sizeof(*ip) / sizeof(uint16_t); ++i)
        sum += words[i];
    sum = (sum & 0xffffu) + (sum >> 16u);
    sum = (sum & 0xffffu) + (sum >> 16u);
    return static_cast<uint16_t>(~sum);
}

bool make_response(void *packet, uint32_t *length)
{
    if (*length < sizeof(ethhdr) + sizeof(iphdr) + sizeof(udphdr))
        return false;
    auto *eth = static_cast<ethhdr *>(packet);
    if (ntohs(eth->h_proto) != ETH_P_IP)
        return false;
    auto *ip = reinterpret_cast<iphdr *>(eth + 1);
    if (ip->version != 4 || ip->ihl != sizeof(*ip) / 4 ||
        ip->protocol != IPPROTO_UDP ||
        (ntohs(ip->frag_off) & 0x3fffu) != 0)
        return false;
    auto *udp = reinterpret_cast<udphdr *>(ip + 1);
    uint32_t udp_length = ntohs(udp->len);
    if (ntohs(udp->dest) != kServerPort ||
        udp_length != sizeof(*udp) + kRequest.size() ||
        sizeof(*eth) + sizeof(*ip) + udp_length > *length)
        return false;
    auto *payload = reinterpret_cast<uint8_t *>(udp + 1);
    if (std::memcmp(payload, kRequest.data(), kRequest.size()) != 0)
        return false;

    std::array<uint8_t, ETH_ALEN> source_mac = {};
    std::memcpy(source_mac.data(), eth->h_source, ETH_ALEN);
    std::memcpy(eth->h_source, eth->h_dest, ETH_ALEN);
    std::memcpy(eth->h_dest, source_mac.data(), ETH_ALEN);
    std::swap(ip->saddr, ip->daddr);
    std::swap(udp->source, udp->dest);
    std::memcpy(payload, kResponse.data(), kResponse.size());
    udp->len = htons(sizeof(*udp) + kResponse.size());
    udp->check = 0;
    ip->tot_len = htons(sizeof(*ip) + sizeof(*udp) + kResponse.size());
    ip->check = 0;
    ip->check = ipv4_checksum(ip);
    *length = sizeof(*eth) + sizeof(*ip) + sizeof(*udp) + kResponse.size();
    return true;
}

void drain_completions(xsk_ring_cons *completion, std::vector<uint64_t> *free_frames)
{
    uint32_t index = 0;
    uint32_t count = xsk_ring_cons__peek(completion, kBatchSize, &index);
    for (uint32_t i = 0; i < count; ++i)
        free_frames->push_back(*xsk_ring_cons__comp_addr(completion, index + i));
    if (count)
        xsk_ring_cons__release(completion, count);
}

void refill(xsk_ring_prod *fill, std::vector<uint64_t> *free_frames)
{
    uint32_t desired = std::min<uint32_t>(kBatchSize, free_frames->size());
    if (!desired)
        return;
    uint32_t index = 0;
    uint32_t count = xsk_ring_prod__reserve(fill, desired, &index);
    for (uint32_t i = 0; i < count; ++i) {
        *xsk_ring_prod__fill_addr(fill, index + i) = free_frames->back();
        free_frames->pop_back();
    }
    if (count)
        xsk_ring_prod__submit(fill, count);
}

int run(const std::string &ifname, uint32_t queue_id, bool zero_copy,
        const std::string &bpf_object_path)
{
    int ifindex = static_cast<int>(if_nametoindex(ifname.c_str()));
    if (!ifindex) {
        std::cerr << "AF_XDP interface does not exist: " << ifname << "\n";
        return 2;
    }
    size_t umem_size = static_cast<size_t>(kFrameSize) * kFrameCount;
    void *umem_area = nullptr;
    if (posix_memalign(&umem_area, getpagesize(), umem_size) != 0)
        return 2;
    std::memset(umem_area, 0, umem_size);
    if (mlock(umem_area, umem_size) != 0)
        std::cerr << "warning: mlock failed: " << std::strerror(errno) << "\n";

    xsk_ring_prod fill = {};
    xsk_ring_cons completion = {};
    xsk_ring_cons rx = {};
    xsk_ring_prod tx = {};
    xsk_umem *umem = nullptr;
    xsk_socket *xsk = nullptr;
    bpf_object *bpf_object = nullptr;
    bpf_program *redirect_program = nullptr;
    int program_fd = -1;
    int socket_map_fd = -1;
    bool attached = false;
    xsk_umem_config umem_config = {};
    umem_config.fill_size = XSK_RING_PROD__DEFAULT_NUM_DESCS;
    umem_config.comp_size = XSK_RING_CONS__DEFAULT_NUM_DESCS;
    umem_config.frame_size = kFrameSize;
    int error = xsk_umem__create(&umem, umem_area, umem_size, &fill,
                                 &completion, &umem_config);
    if (error) {
        std::cerr << "xsk_umem__create failed: " << std::strerror(-error) << "\n";
        free(umem_area);
        return 2;
    }
    xsk_socket_config socket_config = {};
    socket_config.rx_size = XSK_RING_CONS__DEFAULT_NUM_DESCS;
    socket_config.tx_size = XSK_RING_PROD__DEFAULT_NUM_DESCS;
    socket_config.xdp_flags = XDP_FLAGS_SKB_MODE | XDP_FLAGS_UPDATE_IF_NOEXIST;
    if (!bpf_object_path.empty())
        socket_config.libbpf_flags = XSK_LIBBPF_FLAGS__INHIBIT_PROG_LOAD;
    socket_config.bind_flags = XDP_USE_NEED_WAKEUP |
                               (zero_copy ? XDP_ZEROCOPY : XDP_COPY);
    error = xsk_socket__create(&xsk, ifname.c_str(), queue_id, umem, &rx, &tx,
                               &socket_config);
    if (error) {
        std::cerr << "xsk_socket__create failed: " << std::strerror(-error)
                  << " mode=" << (zero_copy ? "zero-copy" : "copy") << "\n";
        xsk_umem__delete(umem);
        free(umem_area);
        return 2;
    }

    if (!bpf_object_path.empty()) {
        bpf_object = bpf_object__open_file(bpf_object_path.c_str(), nullptr);
        if (!bpf_object) {
            std::cerr << "failed to open redirect BPF object: "
                      << bpf_object_path << "\n";
            xsk_socket__delete(xsk);
            xsk_umem__delete(umem);
            free(umem_area);
            return 2;
        }
        redirect_program = bpf_object__find_program_by_name(
            bpf_object, "af_xdp_udp_redirect");
        bpf_map *socket_map = bpf_object__find_map_by_name(
            bpf_object, "af_xdp_sockets");
        if (!redirect_program || !socket_map) {
            std::cerr << "redirect BPF object is missing program or XSKMAP\n";
            bpf_object__close(bpf_object);
            xsk_socket__delete(xsk);
            xsk_umem__delete(umem);
            free(umem_area);
            return 2;
        }
        bpf_program__set_type(redirect_program, BPF_PROG_TYPE_XDP);
        error = bpf_object__load(bpf_object);
        if (error) {
            std::cerr << "failed to load redirect BPF object: "
                      << std::strerror(-error) << "\n";
            bpf_object__close(bpf_object);
            xsk_socket__delete(xsk);
            xsk_umem__delete(umem);
            free(umem_area);
            return 2;
        }
        program_fd = bpf_program__fd(redirect_program);
        socket_map_fd = bpf_map__fd(socket_map);
        error = bpf_xdp_attach(ifindex, program_fd,
                               XDP_FLAGS_SKB_MODE |
                                   XDP_FLAGS_UPDATE_IF_NOEXIST,
                               nullptr);
        if (error) {
            std::cerr << "failed to attach selective redirect program: "
                      << std::strerror(-error) << "\n";
            bpf_object__close(bpf_object);
            xsk_socket__delete(xsk);
            xsk_umem__delete(umem);
            free(umem_area);
            return 2;
        }
        attached = true;
        int socket_fd = xsk_socket__fd(xsk);
        error = bpf_map_update_elem(socket_map_fd, &queue_id, &socket_fd,
                                    BPF_ANY);
        if (error) {
            std::cerr << "failed to populate AF_XDP socket map: "
                      << std::strerror(errno) << "\n";
            bpf_xdp_attach_opts detach_options = {};
            detach_options.sz = sizeof(detach_options);
            detach_options.old_prog_fd = program_fd;
            bpf_xdp_detach(ifindex, XDP_FLAGS_SKB_MODE, &detach_options);
            bpf_object__close(bpf_object);
            xsk_socket__delete(xsk);
            xsk_umem__delete(umem);
            free(umem_area);
            return 2;
        }
    }

    std::vector<uint64_t> free_frames;
    free_frames.reserve(kFrameCount);
    for (uint32_t i = 0; i < kFrameCount; ++i)
        free_frames.push_back(static_cast<uint64_t>(i) * kFrameSize);
    refill(&fill, &free_frames);

    Counters counters;
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    int fd = xsk_socket__fd(xsk);
    std::cout << "af_xdp_udp_responder attached dev=" << ifname
              << " queue=" << queue_id
              << " mode=" << (zero_copy ? "zero-copy" : "copy")
              << std::endl;
    while (!exiting) {
        drain_completions(&completion, &free_frames);
        refill(&fill, &free_frames);
        pollfd descriptor = {fd, POLLIN, 0};
        int ready = poll(&descriptor, 1, 100);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        uint32_t rx_index = 0;
        uint32_t received = xsk_ring_cons__peek(&rx, kBatchSize, &rx_index);
        if (!received)
            continue;
        for (uint32_t i = 0; i < received; ++i) {
            const xdp_desc *input = xsk_ring_cons__rx_desc(&rx, rx_index + i);
            uint64_t address = xsk_umem__extract_addr(input->addr);
            uint64_t offset = xsk_umem__extract_offset(input->addr);
            void *packet = xsk_umem__get_data(umem_area, address + offset);
            uint32_t length = input->len;
            counters.rx++;
            if (!make_response(packet, &length)) {
                counters.pass++;
                free_frames.push_back(address);
                continue;
            }
            uint32_t tx_index = 0;
            if (!xsk_ring_prod__reserve(&tx, 1, &tx_index)) {
                counters.tx_full++;
                free_frames.push_back(address);
                continue;
            }
            xdp_desc *output = xsk_ring_prod__tx_desc(&tx, tx_index);
            output->addr = address;
            output->len = length;
            xsk_ring_prod__submit(&tx, 1);
            counters.hit++;
            counters.tx++;
        }
        xsk_ring_cons__release(&rx, received);
        if (xsk_ring_prod__needs_wakeup(&tx))
            sendto(fd, nullptr, 0, MSG_DONTWAIT, nullptr, 0);
    }

    std::cout << "af_xdp_udp_responder rx=" << counters.rx
              << " hit=" << counters.hit << " pass=" << counters.pass
              << " tx=" << counters.tx << " tx_full=" << counters.tx_full
              << " invalid=" << counters.invalid << "\n";
    if (socket_map_fd >= 0)
        bpf_map_delete_elem(socket_map_fd, &queue_id);
    if (attached) {
        bpf_xdp_attach_opts detach_options = {};
        detach_options.sz = sizeof(detach_options);
        detach_options.old_prog_fd = program_fd;
        int detach_error = bpf_xdp_detach(ifindex, XDP_FLAGS_SKB_MODE,
                                          &detach_options);
        if (detach_error && detach_error != -ENOENT)
            std::cerr << "refusing to detach a different XDP program: "
                      << std::strerror(-detach_error) << "\n";
    }
    if (bpf_object)
        bpf_object__close(bpf_object);
    xsk_socket__delete(xsk);
    xsk_umem__delete(umem);
    munlock(umem_area, umem_size);
    free(umem_area);
    return 0;
}

} // namespace

int main(int argc, char **argv)
{
    std::string ifname;
    uint32_t queue_id = 0;
    bool zero_copy = false;
    std::string bpf_object_path;
    for (int i = 1; i < argc; ++i) {
        std::string argument = argv[i];
        if (argument == "--dev" && i + 1 < argc)
            ifname = argv[++i];
        else if (argument == "--queue" && i + 1 < argc)
            queue_id = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 10));
        else if (argument == "--zero-copy")
            zero_copy = true;
        else if (argument == "--copy")
            zero_copy = false;
        else if (argument == "--bpf-object" && i + 1 < argc)
            bpf_object_path = argv[++i];
        else {
            std::cerr << "Usage: " << argv[0]
                      << " --dev IFACE [--queue N] [--copy|--zero-copy]"
                      << " [--bpf-object PATH]\n";
            return 2;
        }
    }
    if (ifname.empty())
        return 2;
    return run(ifname, queue_id, zero_copy, bpf_object_path);
}
