#include "bpf_cache_policy_publisher.hpp"
#include "dynamic_cache_controller.hpp"

#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct Options {
    DynamicCacheConfig config;
    std::string metrics_file;
    std::string audit_log;
    std::vector<std::string> control_maps;
    bool dry_run = false;
};

class DryRunPublisher final : public CachePolicyPublisher {
public:
    bool publish(CacheMode mode, uint64_t epoch, std::string *) override
    {
        std::cout << "dynamic_cache_publish mode=" << cache_mode_name(mode)
                  << " epoch=" << epoch << " dry_run=1\n";
        return true;
    }
};

void usage(const char *program)
{
    std::cerr
        << "Usage: " << program
        << " [--metrics-file <csv>] [--control-map <pinned-map>]..."
        << " [--dry-run] [--audit-log <path>]"
        << " [--initial-mode bypass|server|client|dual]"
        << " [--window-size <n>] [--required-windows <n>]"
        << " [--cooldown-ms <n>] [--min-window-requests <n>]\n"
        << "CSV columns: timestamp_ms,dns_hits,dns_misses,dns_p95_us,"
        << "grpc_hits,grpc_misses,grpc_p95_us,backend_qps,error_rate\n";
}

bool parse_u64(const std::string &text, uint64_t *value)
{
    if (text.empty() || text[0] == '-')
        return false;
    errno = 0;
    char *end = nullptr;
    unsigned long long parsed = std::strtoull(text.c_str(), &end, 10);
    if (errno == ERANGE || !end || *end != '\0')
        return false;
    *value = static_cast<uint64_t>(parsed);
    return true;
}

bool parse_size(const std::string &text, size_t *value)
{
    uint64_t parsed = 0;
    if (!parse_u64(text, &parsed) || parsed == 0)
        return false;
    *value = static_cast<size_t>(parsed);
    return true;
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--metrics-file" && i + 1 < argc) {
            options->metrics_file = argv[++i];
        } else if (arg == "--control-map" && i + 1 < argc) {
            options->control_maps.emplace_back(argv[++i]);
        } else if (arg == "--audit-log" && i + 1 < argc) {
            options->audit_log = argv[++i];
        } else if (arg == "--dry-run") {
            options->dry_run = true;
        } else if (arg == "--initial-mode" && i + 1 < argc) {
            if (!parse_cache_mode(argv[++i], &options->config.initial_mode))
                return false;
        } else if (arg == "--window-size" && i + 1 < argc) {
            if (!parse_size(argv[++i], &options->config.window_size))
                return false;
        } else if (arg == "--required-windows" && i + 1 < argc) {
            if (!parse_size(argv[++i], &options->config.required_windows))
                return false;
        } else if (arg == "--cooldown-ms" && i + 1 < argc) {
            if (!parse_u64(argv[++i], &options->config.cooldown_ms))
                return false;
        } else if (arg == "--min-window-requests" && i + 1 < argc) {
            if (!parse_u64(argv[++i], &options->config.min_window_requests))
                return false;
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }
    const bool has_control_maps = !options->control_maps.empty();
    return options->dry_run != has_control_maps;
}

std::vector<std::string> split_csv(const std::string &line)
{
    std::vector<std::string> fields;
    std::stringstream stream(line);
    std::string field;
    while (std::getline(stream, field, ','))
        fields.push_back(field);
    return fields;
}

bool parse_double(const std::string &text, double *value)
{
    errno = 0;
    char *end = nullptr;
    double parsed = std::strtod(text.c_str(), &end);
    if (errno == ERANGE || !end || *end != '\0' ||
        !std::isfinite(parsed))
        return false;
    *value = parsed;
    return true;
}

bool parse_sample(const std::string &line, CacheMetricSample *sample)
{
    const std::vector<std::string> fields = split_csv(line);
    if (fields.size() != 9)
        return false;
    if (!parse_u64(fields[0], &sample->timestamp_ms) ||
        !parse_u64(fields[1], &sample->dns_hits) ||
        !parse_u64(fields[2], &sample->dns_misses) ||
        !parse_double(fields[3], &sample->dns_p95_us) ||
        !parse_u64(fields[4], &sample->grpc_hits) ||
        !parse_u64(fields[5], &sample->grpc_misses) ||
        !parse_double(fields[6], &sample->grpc_p95_us) ||
        !parse_double(fields[7], &sample->backend_qps) ||
        !parse_double(fields[8], &sample->error_rate))
        return false;
    return sample->dns_p95_us >= 0.0 && sample->grpc_p95_us >= 0.0 &&
           sample->backend_qps >= 0.0 && sample->error_rate >= 0.0 &&
           sample->error_rate <= 1.0;
}

std::string result_line(const CacheMetricSample &sample,
                        const DynamicCacheResult &result)
{
    std::ostringstream output;
    output << std::fixed << std::setprecision(4)
           << "dynamic_cache_decision"
           << " timestamp_ms=" << sample.timestamp_ms
           << " mode=" << cache_mode_name(result.mode)
           << " candidate=" << cache_mode_name(result.candidate)
           << " epoch=" << result.epoch
           << " window_ready=" << result.window_ready
           << " changed=" << result.changed
           << " publish_failed=" << result.publish_failed
           << " hit_ratio=" << result.hit_ratio
           << " p95_us=" << result.p95_us
           << " backend_qps=" << result.backend_qps
           << " error_rate=" << result.error_rate
           << " reason=" << result.reason;
    return output.str();
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        usage(argv[0]);
        return 1;
    }

    std::unique_ptr<CachePolicyPublisher> publisher;
    if (options.dry_run)
        publisher = std::make_unique<DryRunPublisher>();
    else
        publisher = std::make_unique<BpfCachePolicyPublisher>(
            options.control_maps);

    constexpr uint64_t startup_epoch = 1;
    std::string publish_error;
    if (!publisher->publish(options.config.initial_mode, startup_epoch,
                            &publish_error)) {
        std::cerr << "Failed to publish initial cache mode: "
                  << publish_error << "\n";
        return 1;
    }
    options.config.initial_epoch = startup_epoch;

    std::ifstream metrics_file;
    std::istream *input = &std::cin;
    if (!options.metrics_file.empty()) {
        metrics_file.open(options.metrics_file);
        if (!metrics_file) {
            std::cerr << "Failed to open metrics file "
                      << options.metrics_file << "\n";
            return 1;
        }
        input = &metrics_file;
    }

    std::ofstream audit;
    if (!options.audit_log.empty()) {
        audit.open(options.audit_log, std::ios::app);
        if (!audit) {
            std::cerr << "Failed to open audit log " << options.audit_log
                      << "\n";
            return 1;
        }
    }

    DynamicCacheController controller(options.config, publisher.get());
    std::string line;
    size_t line_number = 0;
    while (std::getline(*input, line)) {
        line_number++;
        if (line.empty() || line[0] == '#' ||
            line.rfind("timestamp_ms,", 0) == 0)
            continue;

        CacheMetricSample sample;
        if (!parse_sample(line, &sample)) {
            std::cerr << "Invalid metrics CSV line " << line_number << "\n";
            return 1;
        }
        const DynamicCacheResult result = controller.observe(sample);
        const std::string output = result_line(sample, result);
        std::cout << output << "\n";
        if (audit) {
            audit << output << "\n";
            audit.flush();
        }
    }
    return 0;
}
