#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef SO_MAX_PACING_RATE
#define SO_MAX_PACING_RATE 47
#endif

#define MAX_BATCH 128
#define MAX_PACKET 512
#define MAX_DOMAIN 253
#define MAX_QUERY_LINE 512
#define MAX_HIST_US 200000
#define DEFAULT_PORT 53
#define DEFAULT_DURATION_SEC 3
#define DEFAULT_THREADS 4
#define DEFAULT_BATCH 32
#define DEFAULT_TIMEOUT_US 50000

struct options {
    char target[INET_ADDRSTRLEN];
    char domain[MAX_DOMAIN + 1];
    char queries_path[PATH_MAX];
    int port;
    uint64_t rate;
    int duration_sec;
    int threads;
    int batch;
    int timeout_us;
    int cpu_base;
};

struct pending_query {
    uint64_t sent_ns;
    uint64_t batch_no;
    size_t query_index;
    int active;
};

struct query_spec {
    uint8_t qname[MAX_DOMAIN + 2];
    size_t qname_len;
    uint16_t qtype;
};

struct run_state {
    struct options opt;
    const struct query_spec *queries;
    size_t query_count;
    pthread_barrier_t barrier;
    uint64_t start_ns;
    uint64_t end_ns;
};

struct thread_stats {
    uint64_t offered;
    uint64_t sent;
    uint64_t received;
    uint64_t lost;
    uint64_t send_errors;
    uint64_t unexpected;
    uint64_t invalid;
    uint64_t affinity_errors;
    uint64_t latency_sum_us;
    uint64_t hist[MAX_HIST_US + 1];
};

struct thread_ctx {
    struct run_state *run;
    int index;
    int cpu;
    int fd;
    struct pending_query *pending;
    struct thread_stats stats;
};

static uint64_t monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s --target IPv4 --rate QPS [options]\n"
            "  --target IP       DNS server address\n"
            "  --rate QPS        offered request rate, divided across threads\n"
            "  --duration SEC    run length (default %d)\n"
            "  --threads N       persistent UDP sockets/threads (default %d)\n"
            "  --batch N         sendmmsg/recvmmsg batch size (default %d)\n"
            "  --timeout-us N    per-batch receive deadline (default %d)\n"
            "  --cpu-base N      first client CPU; thread i uses N+i (default 2)\n"
            "  --port N          UDP port (default %d)\n"
            "  --domain NAME     DNS name when --queries is absent (default example.test)\n"
            "  --queries FILE    corpus lines containing '<name> <QTYPE>'\n",
            prog, DEFAULT_DURATION_SEC, DEFAULT_THREADS, DEFAULT_BATCH,
            DEFAULT_TIMEOUT_US, DEFAULT_PORT);
}

static int parse_int(const char *value, const char *name, int min, int max)
{
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (!value[0] || !end || *end || parsed < min || parsed > max) {
        fprintf(stderr, "invalid %s: %s\n", name, value);
        exit(EXIT_FAILURE);
    }
    return (int)parsed;
}

static uint64_t parse_u64(const char *value, const char *name, uint64_t min,
                          uint64_t max)
{
    char *end = NULL;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (!value[0] || !end || *end || parsed < min || parsed > max) {
        fprintf(stderr, "invalid %s: %s\n", name, value);
        exit(EXIT_FAILURE);
    }
    return (uint64_t)parsed;
}

static void parse_args(int argc, char **argv, struct options *opt)
{
    memset(opt, 0, sizeof(*opt));
    opt->port = DEFAULT_PORT;
    opt->duration_sec = DEFAULT_DURATION_SEC;
    opt->threads = DEFAULT_THREADS;
    opt->batch = DEFAULT_BATCH;
    opt->timeout_us = DEFAULT_TIMEOUT_US;
    opt->cpu_base = 2;
    strncpy(opt->domain, "example.test", sizeof(opt->domain) - 1);

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (!strcmp(arg, "--target") && i + 1 < argc) {
            strncpy(opt->target, argv[++i], sizeof(opt->target) - 1);
        } else if (!strcmp(arg, "--rate") && i + 1 < argc) {
            opt->rate = parse_u64(argv[++i], "rate", 1, 100000000ULL);
        } else if (!strcmp(arg, "--duration") && i + 1 < argc) {
            opt->duration_sec = parse_int(argv[++i], "duration", 1, 60);
        } else if (!strcmp(arg, "--threads") && i + 1 < argc) {
            opt->threads = parse_int(argv[++i], "threads", 1, 64);
        } else if (!strcmp(arg, "--batch") && i + 1 < argc) {
            opt->batch = parse_int(argv[++i], "batch", 1, MAX_BATCH);
        } else if (!strcmp(arg, "--timeout-us") && i + 1 < argc) {
            opt->timeout_us = parse_int(argv[++i], "timeout-us", 1000, 1000000);
        } else if (!strcmp(arg, "--cpu-base") && i + 1 < argc) {
            opt->cpu_base = parse_int(argv[++i], "cpu-base", 0, 4095);
        } else if (!strcmp(arg, "--port") && i + 1 < argc) {
            opt->port = parse_int(argv[++i], "port", 1, 65535);
        } else if (!strcmp(arg, "--domain") && i + 1 < argc) {
            strncpy(opt->domain, argv[++i], sizeof(opt->domain) - 1);
            opt->domain[sizeof(opt->domain) - 1] = '\0';
        } else if (!strcmp(arg, "--queries") && i + 1 < argc) {
            strncpy(opt->queries_path, argv[++i], sizeof(opt->queries_path) - 1);
            opt->queries_path[sizeof(opt->queries_path) - 1] = '\0';
        } else {
            usage(argv[0]);
            exit(EXIT_FAILURE);
        }
    }

    if (!opt->target[0] || !opt->rate) {
        usage(argv[0]);
        exit(EXIT_FAILURE);
    }
    struct in_addr ignored;
    if (inet_pton(AF_INET, opt->target, &ignored) != 1) {
        fprintf(stderr, "target must be an IPv4 address: %s\n", opt->target);
        exit(EXIT_FAILURE);
    }
}

static size_t encode_qname(const char *domain, uint8_t *out, size_t cap)
{
    size_t out_len = 0;
    const char *label = domain;

    while (*label) {
        const char *dot = strchr(label, '.');
        size_t label_len = dot ? (size_t)(dot - label) : strlen(label);
        if (!label_len || label_len > 63 || out_len + label_len + 2 > cap) {
            return 0;
        }
        out[out_len++] = (uint8_t)label_len;
        memcpy(out + out_len, label, label_len);
        out_len += label_len;
        if (!dot) {
            break;
        }
        label = dot + 1;
    }
    if (out_len + 1 > cap) {
        return 0;
    }
    out[out_len++] = 0;
    return out_len;
}

static size_t build_query(uint8_t *buf, size_t cap, uint16_t id,
                          const struct query_spec *query)
{
    const uint8_t *qname = query->qname;
    size_t qname_len = query->qname_len;
    const size_t needed = 12 + qname_len + 4;
    if (cap < needed) {
        return 0;
    }
    memset(buf, 0, needed);
    buf[0] = (uint8_t)(id >> 8);
    buf[1] = (uint8_t)id;
    buf[2] = 0x01;
    buf[5] = 0x01;
    memcpy(buf + 12, qname, qname_len);
    buf[12 + qname_len] = (uint8_t)(query->qtype >> 8);
    buf[13 + qname_len] = (uint8_t)query->qtype;
    buf[14 + qname_len] = 0;
    buf[15 + qname_len] = 1;
    return needed;
}

static int response_matches(const uint8_t *buf, size_t len, uint16_t id,
                            const struct query_spec *query)
{
    const uint8_t *qname = query->qname;
    size_t qname_len = query->qname_len;
    const size_t question_len = 12 + qname_len + 4;
    if (len < question_len || buf[0] != (uint8_t)(id >> 8) ||
        buf[1] != (uint8_t)id || !(buf[2] & 0x80) || !(buf[3] & 0x80) ||
        memcmp(buf + 12, qname, qname_len) != 0 ||
        buf[12 + qname_len] != (uint8_t)(query->qtype >> 8) ||
        buf[13 + qname_len] != (uint8_t)query->qtype ||
        buf[14 + qname_len] != 0 || buf[15 + qname_len] != 1) {
        return 0;
    }
    return 1;
}

static uint16_t parse_qtype(const char *text)
{
    if (!strcmp(text, "A")) {
        return 1;
    }
    if (!strcmp(text, "AAAA")) {
        return 28;
    }
    if (!strcmp(text, "HTTPS")) {
        return 65;
    }
    if (!strcmp(text, "PTR")) {
        return 12;
    }
    if (!strcmp(text, "CNAME")) {
        return 5;
    }
    if (!strcmp(text, "TXT")) {
        return 16;
    }
    if (!strcmp(text, "MX")) {
        return 15;
    }
    if (!strcmp(text, "NS")) {
        return 2;
    }
    return 0;
}

static struct query_spec *load_queries(const char *path, size_t *count_out)
{
    FILE *input = fopen(path, "r");
    if (!input) {
        fprintf(stderr, "could not open query corpus %s: %s\n", path,
                strerror(errno));
        return NULL;
    }

    size_t capacity = 1024;
    size_t count = 0;
    struct query_spec *queries = calloc(capacity, sizeof(*queries));
    if (!queries) {
        fclose(input);
        perror("calloc query corpus");
        return NULL;
    }

    char line[MAX_QUERY_LINE];
    unsigned long line_number = 0;
    while (fgets(line, sizeof(line), input)) {
        line_number++;
        char name[MAX_DOMAIN + 1];
        char type[16];
        int fields = sscanf(line, " %253s %15s", name, type);
        if (!fields || line[0] == '#' || line[0] == '\n') {
            continue;
        }
        if (fields != 2) {
            fprintf(stderr, "invalid query corpus line %lu\n", line_number);
            free(queries);
            fclose(input);
            return NULL;
        }
        uint16_t qtype = parse_qtype(type);
        if (!qtype) {
            fprintf(stderr, "unsupported QTYPE %s on corpus line %lu\n", type,
                    line_number);
            free(queries);
            fclose(input);
            return NULL;
        }
        if (count == capacity) {
            capacity *= 2;
            struct query_spec *grown = realloc(queries,
                                                capacity * sizeof(*queries));
            if (!grown) {
                perror("realloc query corpus");
                free(queries);
                fclose(input);
                return NULL;
            }
            queries = grown;
        }
        struct query_spec *query = &queries[count];
        query->qname_len = encode_qname(name, query->qname,
                                         sizeof(query->qname));
        query->qtype = qtype;
        if (!query->qname_len) {
            fprintf(stderr, "invalid query name on corpus line %lu\n",
                    line_number);
            free(queries);
            fclose(input);
            return NULL;
        }
        count++;
    }
    int read_error = ferror(input);
    fclose(input);
    if (read_error || !count) {
        fprintf(stderr, "query corpus %s is empty or unreadable\n", path);
        free(queries);
        return NULL;
    }
    *count_out = count;
    return queries;
}

static void record_latency(struct thread_stats *stats, uint64_t latency_ns)
{
    uint64_t us = latency_ns / 1000ULL;
    if (us > MAX_HIST_US) {
        us = MAX_HIST_US;
    }
    stats->latency_sum_us += us;
    stats->hist[us]++;
}

static int set_thread_affinity(int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    return pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

static int open_socket(const struct options *opt)
{
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    if (fd < 0) {
        return -1;
    }
    int buffer = 4 * 1024 * 1024;
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
    struct sockaddr_in peer = {
        .sin_family = AF_INET,
        .sin_port = htons((uint16_t)opt->port),
    };
    inet_pton(AF_INET, opt->target, &peer.sin_addr);
    if (connect(fd, (const struct sockaddr *)&peer, sizeof(peer)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void drain_responses(struct thread_ctx *ctx, int budget_us,
                            int wait_for_data)
{
    struct mmsghdr messages[MAX_BATCH];
    struct iovec iov[MAX_BATCH];
    uint8_t data[MAX_BATCH][MAX_PACKET];
    uint64_t deadline = monotonic_ns() + (uint64_t)budget_us * 1000ULL;

    memset(messages, 0, sizeof(messages));
    for (int i = 0; i < MAX_BATCH; i++) {
        iov[i].iov_base = data[i];
        iov[i].iov_len = sizeof(data[i]);
        messages[i].msg_hdr.msg_iov = &iov[i];
        messages[i].msg_hdr.msg_iovlen = 1;
    }

    while (monotonic_ns() < deadline) {
        int received = recvmmsg(ctx->fd, messages, MAX_BATCH, MSG_DONTWAIT,
                                NULL);
        if (received < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                if (!wait_for_data) {
                    break;
                }
                uint64_t now = monotonic_ns();
                if (now >= deadline) {
                    break;
                }
                uint64_t remaining_us = (deadline - now + 999ULL) / 1000ULL;
                int timeout_ms = (int)((remaining_us + 999ULL) / 1000ULL);
                struct pollfd pfd = {
                    .fd = ctx->fd,
                    .events = POLLIN,
                };
                int ready = poll(&pfd, 1, timeout_ms);
                if (ready > 0) {
                    continue;
                }
                if (ready < 0 && errno == EINTR) {
                    continue;
                }
                break;
            }
            break;
        }
        uint64_t response_ns = monotonic_ns();
        for (int i = 0; i < received; i++) {
            size_t len = messages[i].msg_len;
            if (len < 2) {
                ctx->stats.invalid++;
                continue;
            }
            uint16_t id = (uint16_t)((data[i][0] << 8) | data[i][1]);
            struct pending_query *pending = &ctx->pending[id];
            if (!pending->active) {
                ctx->stats.unexpected++;
                continue;
            }
            const struct query_spec *query =
                &ctx->run->queries[pending->query_index];
            if (!response_matches(data[i], len, id, query)) {
                ctx->stats.invalid++;
                continue;
            }
            uint64_t sent_ns = pending->sent_ns;
            pending->active = 0;
            ctx->stats.received++;
            record_latency(&ctx->stats, response_ns - sent_ns);
        }
    }
}

static void *client_thread(void *arg)
{
    struct thread_ctx *ctx = arg;
    const struct options *opt = &ctx->run->opt;
    struct mmsghdr messages[MAX_BATCH];
    struct iovec iov[MAX_BATCH];
    uint8_t data[MAX_BATCH][MAX_PACKET];
    uint16_t ids[MAX_BATCH];
    size_t query_indices[MAX_BATCH];
    uint64_t sequence = (uint64_t)ctx->index << 16;
    uint64_t query_sequence = (uint64_t)ctx->index * (uint64_t)opt->batch;
    uint64_t batch_no = 0;
    uint64_t thread_rate = opt->rate / (uint64_t)opt->threads;
    uint64_t remainder = opt->rate % (uint64_t)opt->threads;
    if ((uint64_t)ctx->index < remainder) {
        thread_rate++;
    }

    if (set_thread_affinity(ctx->cpu) != 0) {
        ctx->stats.affinity_errors++;
    }
    ctx->fd = open_socket(opt);
    if (ctx->fd < 0) {
        fprintf(stderr, "thread %d: socket/connect failed: %s\n", ctx->index,
                strerror(errno));
        return NULL;
    }
    memset(ctx->pending, 0, 65536 * sizeof(*ctx->pending));

    pthread_barrier_wait(&ctx->run->barrier);
    uint64_t next_send_ns = ctx->run->start_ns;
    uint64_t batch_interval_ns = 1;
    if (thread_rate) {
        batch_interval_ns = ((uint64_t)opt->batch * 1000000000ULL +
                             thread_rate - 1) /
                            thread_rate;
        if (!batch_interval_ns) {
            batch_interval_ns = 1;
        }
    }

    while (monotonic_ns() < ctx->run->end_ns) {
        uint64_t before_send = monotonic_ns();
        if (before_send < next_send_ns) {
            uint64_t wait_us = (next_send_ns - before_send + 999ULL) / 1000ULL;
            drain_responses(ctx, (int)wait_us, 1);
        }
        uint64_t now = monotonic_ns();
        if (now >= ctx->run->end_ns) {
            break;
        }

        int requested = 0;
        for (int i = 0; i < opt->batch; i++) {
            uint16_t id = (uint16_t)sequence++;
            int attempts = 0;
            while (ctx->pending[id].active && attempts++ < 65536) {
                id = (uint16_t)sequence++;
            }
            if (ctx->pending[id].active) {
                ctx->stats.send_errors++;
                continue;
            }
            size_t query_index =
                (query_sequence + (uint64_t)i) % ctx->run->query_count;
            const struct query_spec *query = &ctx->run->queries[query_index];
            size_t len = build_query(data[requested], sizeof(data[requested]),
                                     id, query);
            if (!len) {
                ctx->stats.send_errors++;
                continue;
            }
            memset(&messages[requested], 0, sizeof(messages[requested]));
            iov[requested].iov_base = data[requested];
            iov[requested].iov_len = len;
            messages[requested].msg_hdr.msg_iov = &iov[requested];
            messages[requested].msg_hdr.msg_iovlen = 1;
            ids[requested] = id;
            query_indices[requested] = query_index;
            requested++;
        }
        ctx->stats.offered += (uint64_t)opt->batch;
        if (requested) {
            int sent = sendmmsg(ctx->fd, messages, (unsigned int)requested,
                                MSG_DONTWAIT);
            if (sent < 0) {
                if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    ctx->stats.send_errors += (uint64_t)requested;
                } else {
                    ctx->stats.lost += (uint64_t)requested;
                }
                sent = 0;
            }
            ctx->stats.sent += (uint64_t)sent;
            if (sent < requested) {
                ctx->stats.lost += (uint64_t)(requested - sent);
            }
            uint64_t sent_ns = monotonic_ns();
            for (int i = 0; i < sent; i++) {
                ctx->pending[ids[i]].sent_ns = sent_ns;
                ctx->pending[ids[i]].batch_no = batch_no;
                ctx->pending[ids[i]].query_index = query_indices[i];
                ctx->pending[ids[i]].active = 1;
            }
            /* Drain without waiting for every response, so one lost packet
             * cannot throttle the offered rate.  Older responses remain
             * addressable through the persistent ID table. */
            drain_responses(ctx, 200, 0);
        }
        batch_no++;
        query_sequence += (uint64_t)opt->batch;
        next_send_ns += batch_interval_ns;
        now = monotonic_ns();
        if (next_send_ns + batch_interval_ns * 4 < now) {
            next_send_ns = now;
        }
    }

    /* Give replies already in flight a bounded final chance, then classify
     * every still-active query as lost. */
    drain_responses(ctx, opt->timeout_us, 1);
    for (size_t id = 0; id < 65536; id++) {
        if (ctx->pending[id].active) {
            ctx->pending[id].active = 0;
            ctx->stats.lost++;
        }
    }
    close(ctx->fd);
    ctx->fd = -1;
    free(ctx->pending);
    ctx->pending = NULL;
    return NULL;
}

static uint64_t percentile(const uint64_t *hist, uint64_t total,
                           unsigned int numerator, unsigned int denominator)
{
    if (!total) {
        return 0;
    }
    uint64_t rank = ((total * numerator) + denominator - 1) / denominator;
    if (!rank) {
        rank = 1;
    }
    uint64_t seen = 0;
    for (uint64_t us = 0; us <= MAX_HIST_US; us++) {
        seen += hist[us];
        if (seen >= rank) {
            return us;
        }
    }
    return MAX_HIST_US;
}

static void add_rusage(const struct rusage *before, const struct rusage *after,
                       double *user_ms, double *sys_ms, uint64_t *nvcsw,
                       uint64_t *nivcsw)
{
    *user_ms = (after->ru_utime.tv_sec - before->ru_utime.tv_sec) * 1000.0 +
               (after->ru_utime.tv_usec - before->ru_utime.tv_usec) / 1000.0;
    *sys_ms = (after->ru_stime.tv_sec - before->ru_stime.tv_sec) * 1000.0 +
              (after->ru_stime.tv_usec - before->ru_stime.tv_usec) / 1000.0;
    *nvcsw = (uint64_t)(after->ru_nvcsw - before->ru_nvcsw);
    *nivcsw = (uint64_t)(after->ru_nivcsw - before->ru_nivcsw);
}

int main(int argc, char **argv)
{
    struct options opt;
    parse_args(argc, argv, &opt);
    struct query_spec fallback_query;
    memset(&fallback_query, 0, sizeof(fallback_query));
    fallback_query.qname_len = encode_qname(
        opt.domain, fallback_query.qname, sizeof(fallback_query.qname));
    fallback_query.qtype = 1;

    size_t query_count = 1;
    struct query_spec *loaded_queries = NULL;
    const struct query_spec *queries = &fallback_query;
    if (opt.queries_path[0]) {
        loaded_queries = load_queries(opt.queries_path, &query_count);
        if (!loaded_queries) {
            return EXIT_FAILURE;
        }
        queries = loaded_queries;
    } else if (!fallback_query.qname_len) {
        fprintf(stderr, "invalid domain: %s\n", opt.domain);
        return EXIT_FAILURE;
    }
    long online_cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (opt.cpu_base + opt.threads > online_cpus) {
        fprintf(stderr, "cpu range %d..%d exceeds %ld online CPUs\n",
                opt.cpu_base, opt.cpu_base + opt.threads - 1, online_cpus);
        free(loaded_queries);
        return EXIT_FAILURE;
    }

    struct run_state run = {
        .opt = opt,
        .queries = queries,
        .query_count = query_count,
    };
    pthread_barrier_init(&run.barrier, NULL, (unsigned)opt.threads + 1U);
    pthread_t *threads = calloc((size_t)opt.threads, sizeof(*threads));
    struct thread_ctx *contexts = calloc((size_t)opt.threads, sizeof(*contexts));
    if (!threads || !contexts) {
        perror("calloc");
        free(loaded_queries);
        return EXIT_FAILURE;
    }

    struct rusage usage_before, usage_after;
    getrusage(RUSAGE_SELF, &usage_before);
    for (int i = 0; i < opt.threads; i++) {
        contexts[i].run = &run;
        contexts[i].index = i;
        contexts[i].cpu = opt.cpu_base + i;
        contexts[i].fd = -1;
        contexts[i].pending = calloc(65536, sizeof(*contexts[i].pending));
        if (!contexts[i].pending ||
            pthread_create(&threads[i], NULL, client_thread, &contexts[i]) != 0) {
            fprintf(stderr, "could not create client thread %d\n", i);
            return EXIT_FAILURE;
        }
    }
    run.start_ns = monotonic_ns() + 500000000ULL;
    run.end_ns = run.start_ns + (uint64_t)opt.duration_sec * 1000000000ULL;
    pthread_barrier_wait(&run.barrier);
    for (int i = 0; i < opt.threads; i++) {
        pthread_join(threads[i], NULL);
    }
    getrusage(RUSAGE_SELF, &usage_after);

    uint64_t hist[MAX_HIST_US + 1];
    memset(hist, 0, sizeof(hist));
    uint64_t offered = 0, sent = 0, received = 0, lost = 0, send_errors = 0;
    uint64_t unexpected = 0, invalid = 0, affinity_errors = 0, latency_sum = 0;
    for (int i = 0; i < opt.threads; i++) {
        offered += contexts[i].stats.offered;
        sent += contexts[i].stats.sent;
        received += contexts[i].stats.received;
        lost += contexts[i].stats.lost;
        send_errors += contexts[i].stats.send_errors;
        unexpected += contexts[i].stats.unexpected;
        invalid += contexts[i].stats.invalid;
        affinity_errors += contexts[i].stats.affinity_errors;
        latency_sum += contexts[i].stats.latency_sum_us;
        for (uint64_t us = 0; us <= MAX_HIST_US; us++) {
            hist[us] += contexts[i].stats.hist[us];
        }
    }
    double user_ms = 0, sys_ms = 0;
    uint64_t nvcsw = 0, nivcsw = 0;
    add_rusage(&usage_before, &usage_after, &user_ms, &sys_ms, &nvcsw,
               &nivcsw);
    double elapsed_sec = (double)(run.end_ns - run.start_ns) / 1e9;
    double qps_sent = sent / elapsed_sec;
    double qps_received = received / elapsed_sec;
    double loss_pct = sent ? ((double)(sent - received) * 100.0 / sent) : 100.0;
    double avg_us = received ? (double)latency_sum / received : 0.0;

    printf("target=%s port=%d offered_rate=%llu duration_sec=%d threads=%d "
           "batch=%d cpu_base=%d offered=%llu sent=%llu received=%llu "
           "lost=%llu send_errors=%llu unexpected=%llu invalid=%llu "
           "qps_sent=%.2f qps_received=%.2f loss_pct=%.4f "
           "avg_us=%.2f p50_us=%llu p95_us=%llu p99_us=%llu "
           "user_cpu_ms=%.2f sys_cpu_ms=%.2f nvcsw=%llu nivcsw=%llu "
           "affinity_errors=%llu query_count=%zu query_file=%s\n",
           opt.target, opt.port, (unsigned long long)opt.rate, opt.duration_sec,
           opt.threads, opt.batch, opt.cpu_base, (unsigned long long)offered,
           (unsigned long long)sent, (unsigned long long)received,
           (unsigned long long)lost, (unsigned long long)send_errors,
           (unsigned long long)unexpected, (unsigned long long)invalid,
           qps_sent, qps_received, loss_pct, avg_us,
           (unsigned long long)percentile(hist, received, 50, 100),
           (unsigned long long)percentile(hist, received, 95, 100),
           (unsigned long long)percentile(hist, received, 99, 100), user_ms,
           sys_ms, (unsigned long long)nvcsw, (unsigned long long)nivcsw,
           (unsigned long long)affinity_errors, query_count,
           opt.queries_path[0] ? opt.queries_path : "<domain>");

    pthread_barrier_destroy(&run.barrier);
    free(threads);
    free(contexts);
    free(loaded_queries);
    return 0;
}
