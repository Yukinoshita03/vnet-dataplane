#include "bpf_cache_policy_publisher.hpp"
#include "dynamic_cache_controller.hpp"

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <fcntl.h>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {

struct Options {
    DynamicCacheConfig config;
    std::string metrics_file;
    std::string audit_log;
    std::vector<std::string> control_maps;
    std::string desired_mode_file;
    uint64_t startup_epoch = 1;
    bool dry_run = false;
};

class DryRunPublisher final : public CachePolicyPublisher {
public:
    bool publish(CacheMode mode, uint64_t epoch, std::string *) override
    {
        std::cout << "dynamic_cache_publish mode=" << cache_mode_name(mode)
                  << " epoch=" << epoch << " dry_run=1\n"
                  << std::flush;
        return true;
    }
};

void append_error(std::string *error, const std::string &message)
{
    if (!error)
        return;
    if (!error->empty())
        *error += "; ";
    *error += message;
}

void close_and_remove_temporary(int *fd, const std::string &path,
                                std::string *error)
{
    if (*fd >= 0) {
        if (close(*fd) != 0)
            append_error(error, "close temporary " + path + ": " +
                                    std::strerror(errno));
        *fd = -1;
    }
    if (unlink(path.c_str()) != 0 && errno != ENOENT)
        append_error(error, "remove temporary " + path + ": " +
                                std::strerror(errno));
}

bool write_all(int fd, const std::string &contents, std::string *error)
{
    const char *data = contents.data();
    size_t remaining = contents.size();
    while (remaining > 0) {
        const ssize_t written = write(fd, data, remaining);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            append_error(error, "write desired mode: " +
                                    std::string(std::strerror(errno)));
            return false;
        }
        if (written == 0) {
            append_error(error, "write desired mode made no progress");
            return false;
        }
        data += written;
        remaining -= static_cast<size_t>(written);
    }
    return true;
}

const char *desired_mode_name(CacheMode mode)
{
    switch (mode) {
    case CacheMode::Bypass:
        return "bypass";
    case CacheMode::ServerCache:
        return "server";
    case CacheMode::ClientCache:
        return "client";
    case CacheMode::DualCache:
        return "dual";
    }
    return nullptr;
}

std::string parent_directory(const std::string &path)
{
    const size_t separator = path.find_last_of('/');
    return separator == std::string::npos
               ? "."
               : (separator == 0 ? "/" : path.substr(0, separator));
}

std::string path_basename(const std::string &path)
{
    const size_t separator = path.find_last_of('/');
    return separator == std::string::npos ? path : path.substr(separator + 1);
}

int lstat_in_directory(int directory_fd, const std::string &path,
                       struct stat *status)
{
    const std::string basename = path_basename(path);
    return fstatat(directory_fd, basename.c_str(), status,
                   AT_SYMLINK_NOFOLLOW);
}

int open_parent_directory(const std::string &path, std::string *parent,
                          std::string *error)
{
    *parent = parent_directory(path);
    int directory_fd =
        open(parent->c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory_fd < 0) {
        append_error(error, "open desired mode directory " + *parent + ": " +
                                std::strerror(errno));
        return -1;
    }
    return directory_fd;
}

bool sync_directory(int directory_fd, const std::string &parent,
                    std::string *error)
{
    if (fsync(directory_fd) != 0) {
        append_error(error, "sync desired mode directory " + parent + ": " +
                                std::strerror(errno));
        return false;
    }
    return true;
}

void close_directory(int directory_fd, const std::string &parent,
                     std::string *error)
{
    if (close(directory_fd) != 0) {
        append_error(error, "close desired mode directory " + parent + ": " +
                                std::strerror(errno));
    }
}

bool preserve_previous_desired_mode(const std::string &path,
                                    std::string *rollback_path,
                                    bool *had_previous,
                                    std::string *error)
{
    struct stat status = {};
    if (lstat(path.c_str(), &status) != 0) {
        if (errno == ENOENT) {
            *had_previous = false;
            return true;
        }
        append_error(error, "inspect previous desired mode " + path + ": " +
                                std::strerror(errno));
        return false;
    }

    // rename cannot replace a directory with the regular temporary file, so
    // preserve the existing failure behavior and let rename report it.
    if (S_ISDIR(status.st_mode)) {
        *had_previous = false;
        return true;
    }

    std::string rollback_template = path + ".rollback.XXXXXX";
    std::vector<char> rollback(rollback_template.begin(),
                               rollback_template.end());
    rollback.push_back('\0');
    int rollback_fd = mkstemp(rollback.data());
    if (rollback_fd < 0) {
        append_error(error, "reserve desired mode rollback path " + path +
                                ": " + std::strerror(errno));
        return false;
    }
    *rollback_path = rollback.data();
    if (close(rollback_fd) != 0) {
        append_error(error, "close desired mode rollback placeholder " +
                                *rollback_path + ": " +
                                std::strerror(errno));
        unlink(rollback_path->c_str());
        return false;
    }
    if (unlink(rollback_path->c_str()) != 0) {
        append_error(error, "remove desired mode rollback placeholder " +
                                *rollback_path + ": " +
                                std::strerror(errno));
        return false;
    }
    if (link(path.c_str(), rollback_path->c_str()) != 0) {
        append_error(error, "preserve previous desired mode " + path + ": " +
                                std::strerror(errno));
        return false;
    }
    *had_previous = true;
    return true;
}

void remove_rollback_file(const std::string &rollback_path,
                          std::string *error)
{
    if (!rollback_path.empty() && unlink(rollback_path.c_str()) != 0 &&
        errno != ENOENT)
        append_error(error, "remove desired mode rollback " + rollback_path +
                                ": " + std::strerror(errno));
}

bool same_file_identity(const struct stat &left, const struct stat &right)
{
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

bool rollback_link_exists(int directory_fd, const std::string &rollback_path)
{
    struct stat status = {};
    return !rollback_path.empty() &&
           lstat_in_directory(directory_fd, rollback_path, &status) == 0;
}

class DesiredModeFilePublisher final : public CachePolicyPublisher {
public:
    explicit DesiredModeFilePublisher(std::string path)
        : path_(std::move(path))
    {
    }

    bool publish(CacheMode mode, uint64_t, std::string *error) override
    {
        const char *mode_name = desired_mode_name(mode);
        if (!mode_name) {
            append_error(error, "unknown desired cache mode");
            return false;
        }

        const std::string contents =
            std::string("{\"schema_version\":1,\"mode\":\"") + mode_name +
            "\"}\n";
        std::string temporary_template = path_ + ".tmp.XXXXXX";
        std::vector<char> temporary(temporary_template.begin(),
                                    temporary_template.end());
        temporary.push_back('\0');
        int fd = mkstemp(temporary.data());
        if (fd < 0) {
            append_error(error, "create temporary " + path_ + ": " +
                                    std::strerror(errno));
            return false;
        }
        const std::string temporary_path(temporary.data());
        if (fchmod(fd, 0644) != 0) {
            append_error(error, "chmod temporary " + temporary_path + ": " +
                                    std::strerror(errno));
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }
        if (!write_all(fd, contents, error)) {
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }
        if (fsync(fd) != 0) {
            append_error(error, "sync temporary " + temporary_path + ": " +
                                    std::strerror(errno));
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }
        struct stat replacement_status = {};
        if (fstat(fd, &replacement_status) != 0) {
            append_error(error, "inspect temporary " + temporary_path + ": " +
                                    std::strerror(errno));
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }
        if (close(fd) != 0) {
            fd = -1;
            append_error(error, "close temporary " + temporary_path + ": " +
                                    std::strerror(errno));
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }
        fd = -1;
        std::string parent;
        int directory_fd = open_parent_directory(path_, &parent, error);
        if (directory_fd < 0) {
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }

        struct stat original_target_status = {};
        bool original_target_known = false;
        if (lstat_in_directory(directory_fd, path_,
                               &original_target_status) == 0) {
            original_target_known = true;
        } else if (errno != ENOENT) {
            append_error(error, "inspect desired mode target " + path_ +
                                    ": " + std::strerror(errno));
            close_directory(directory_fd, parent, error);
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }

        std::string rollback_path;
        bool had_previous = false;
        if (!preserve_previous_desired_mode(path_, &rollback_path,
                                            &had_previous, error)) {
            remove_rollback_file(rollback_path, error);
            close_directory(directory_fd, parent, error);
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }
        struct stat previous_status = {};
        const bool previous_known =
            had_previous &&
            lstat_in_directory(directory_fd, rollback_path,
                               &previous_status) == 0;
        if (had_previous &&
            (!previous_known || !original_target_known ||
             !same_file_identity(previous_status,
                                 original_target_status))) {
            append_error(error, "inspect desired mode rollback " +
                                    rollback_path + ": " +
                                    (previous_known
                                         ? "target changed while preserving"
                                         : std::strerror(errno)));
            remove_rollback_file(rollback_path, error);
            close_directory(directory_fd, parent, error);
            close_and_remove_temporary(&fd, temporary_path, error);
            return false;
        }

        bool replacement_reported_failure = false;
        if (std::rename(temporary_path.c_str(), path_.c_str()) != 0) {
            const int replace_errno = errno;
            append_error(error, "replace desired mode " + path_ + ": " +
                                    std::strerror(replace_errno));

            struct stat visible_status = {};
            if (lstat_in_directory(directory_fd, path_, &visible_status) == 0) {
                if (same_file_identity(visible_status, replacement_status)) {
                    replacement_reported_failure = true;
                } else if (had_previous && previous_known &&
                           same_file_identity(visible_status,
                                              previous_status)) {
                    remove_rollback_file(rollback_path, error);
                    close_directory(directory_fd, parent, error);
                    close_and_remove_temporary(&fd, temporary_path, error);
                    return false;
                } else if (original_target_known &&
                           same_file_identity(visible_status,
                                              original_target_status)) {
                    remove_rollback_file(rollback_path, error);
                    close_directory(directory_fd, parent, error);
                    close_and_remove_temporary(&fd, temporary_path, error);
                    return false;
                }
            } else if (!had_previous && errno == ENOENT) {
                remove_rollback_file(rollback_path, error);
                close_directory(directory_fd, parent, error);
                close_and_remove_temporary(&fd, temporary_path, error);
                return false;
            }

            if (!replacement_reported_failure) {
                const bool rollback_retained =
                    rollback_link_exists(directory_fd, rollback_path);
                close_directory(directory_fd, parent, error);
                std::cerr << "Fatal: desired mode state is indeterminate after "
                             "replacement failure";
                if (rollback_retained)
                    std::cerr << "; recovery link retained at "
                              << rollback_path;
                else if (!rollback_path.empty())
                    std::cerr << "; recovery link is unavailable at "
                              << rollback_path;
                if (error && !error->empty())
                    std::cerr << ": " << *error;
                std::cerr << "\n";
                std::exit(EXIT_FAILURE);
            }
        }

        const bool replacement_known = true;

        if (sync_directory(directory_fd, parent, error)) {
            std::string cleanup_error;
            remove_rollback_file(rollback_path, &cleanup_error);
            if (had_previous)
                (void)sync_directory(directory_fd, parent, &cleanup_error);
            close_directory(directory_fd, parent, &cleanup_error);
            if (!cleanup_error.empty())
                std::cerr << "Warning: desired mode committed with cleanup "
                             "failure: "
                          << cleanup_error << "\n";
            if (replacement_reported_failure) {
                std::cerr << "Warning: desired mode replacement reported "
                             "failure; replacement verified and committed";
                if (error && !error->empty())
                    std::cerr << ": " << *error;
                std::cerr << "\n";
            }
            return true;
        }

        bool restored = false;
        bool replacement_visible = false;
        if (had_previous) {
            if (std::rename(rollback_path.c_str(), path_.c_str()) == 0) {
                restored = true;
            } else {
                append_error(error, "restore previous desired mode " + path_ +
                                        ": " + std::strerror(errno));
            }
        } else {
            if (unlink(path_.c_str()) == 0 || errno == ENOENT) {
                restored = true;
            } else {
                append_error(error, "remove uncommitted desired mode " +
                                        path_ + ": " +
                                        std::strerror(errno));
            }
        }

        if (!restored) {
            struct stat visible_status = {};
            if (lstat_in_directory(directory_fd, path_, &visible_status) == 0) {
                if (had_previous && previous_known &&
                    same_file_identity(visible_status, previous_status)) {
                    restored = true;
                    append_error(error,
                                 "rollback reported failure but previous "
                                 "desired mode is visible");
                    remove_rollback_file(rollback_path, error);
                } else if (replacement_known && same_file_identity(
                                                    visible_status,
                                                    replacement_status)) {
                    replacement_visible = true;
                }
            } else if (!had_previous && errno == ENOENT) {
                restored = true;
            } else {
                append_error(error, "inspect desired mode after rollback " +
                                        path_ + ": " +
                                        std::strerror(errno));
            }
        }

        if (restored) {
            append_error(error, had_previous
                                    ? "previous desired mode restored"
                                    : "uncommitted desired mode removed");
            if (!sync_directory(directory_fd, parent, error)) {
                close_directory(directory_fd, parent, error);
                std::cerr
                    << "Fatal: desired mode rollback directory sync failed";
                if (error && !error->empty())
                    std::cerr << ": " << *error;
                std::cerr << "\n";
                std::exit(EXIT_FAILURE);
            }
            close_directory(directory_fd, parent, error);
            return false;
        }

        if (replacement_visible) {
            std::string commit_error;
            if (!sync_directory(directory_fd, parent, &commit_error)) {
                append_error(error, commit_error);
                close_directory(directory_fd, parent, error);
                std::cerr << "Fatal: desired mode replacement visibility is "
                             "known but commit durability is indeterminate";
                if (error && !error->empty())
                    std::cerr << ": " << *error;
                std::cerr << "\n";
                std::exit(EXIT_FAILURE);
            }
            remove_rollback_file(rollback_path, &commit_error);
            if (had_previous)
                (void)sync_directory(directory_fd, parent, &commit_error);
            close_directory(directory_fd, parent, &commit_error);
            std::cerr << "Warning: desired mode rollback failed; replacement "
                         "verified and committed";
            if (error && !error->empty())
                std::cerr << ": " << *error;
            if (!commit_error.empty())
                std::cerr << "; cleanup: " << commit_error;
            std::cerr << "\n";
            return true;
        }

        const bool rollback_retained =
            rollback_link_exists(directory_fd, rollback_path);
        close_directory(directory_fd, parent, error);
        std::cerr << "Fatal: desired mode state is indeterminate after "
                     "rollback failure";
        if (rollback_retained)
            std::cerr << "; recovery link retained at " << rollback_path;
        else if (!rollback_path.empty())
            std::cerr << "; recovery link is unavailable at "
                      << rollback_path;
        if (error && !error->empty())
            std::cerr << ": " << *error;
        std::cerr << "\n";
        std::exit(EXIT_FAILURE);
    }

private:
    std::string path_;
};

void usage(const char *program)
{
    std::cerr
        << "Usage: " << program
        << " [--metrics-file <csv>] [--control-map <pinned-map>]..."
        << " [--desired-mode-file <absolute-path>] [--dry-run]"
        << " [--audit-log <path>]"
        << " [--initial-mode bypass|server|client|dual]"
        << " [--initial-epoch <n>]"
        << " [--window-size <n>] [--required-windows <n>]"
        << " [--cooldown-ms <n>] [--min-window-requests <n>]"
        << " [--cache-enter-hit-ratio <n>]"
        << " [--cache-exit-hit-ratio <n>]"
        << " [--client-enter-p95-us <n>]"
        << " [--client-exit-p95-us <n>]"
        << " [--dual-enter-backend-qps <n>]"
        << " [--dual-exit-backend-qps <n>]"
        << " [--bypass-error-rate <n>]\n"
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

bool parse_double(const std::string &text, double *value);

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--metrics-file" && i + 1 < argc) {
            options->metrics_file = argv[++i];
        } else if (arg == "--control-map" && i + 1 < argc) {
            options->control_maps.emplace_back(argv[++i]);
        } else if (arg == "--desired-mode-file" && i + 1 < argc) {
            const std::string desired_mode_file = argv[++i];
            if (!options->desired_mode_file.empty() ||
                desired_mode_file.empty())
                return false;
            options->desired_mode_file = desired_mode_file;
        } else if (arg == "--audit-log" && i + 1 < argc) {
            options->audit_log = argv[++i];
        } else if (arg == "--dry-run") {
            options->dry_run = true;
        } else if (arg == "--initial-mode" && i + 1 < argc) {
            if (!parse_cache_mode(argv[++i], &options->config.initial_mode))
                return false;
        } else if (arg == "--initial-epoch" && i + 1 < argc) {
            if (!parse_u64(argv[++i], &options->startup_epoch) ||
                options->startup_epoch == 0)
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
        } else if (arg == "--cache-enter-hit-ratio" && i + 1 < argc) {
            if (!parse_double(argv[++i],
                              &options->config.cache_enter_hit_ratio))
                return false;
        } else if (arg == "--cache-exit-hit-ratio" && i + 1 < argc) {
            if (!parse_double(argv[++i],
                              &options->config.cache_exit_hit_ratio))
                return false;
        } else if (arg == "--client-enter-p95-us" && i + 1 < argc) {
            if (!parse_double(argv[++i],
                              &options->config.client_enter_p95_us))
                return false;
        } else if (arg == "--client-exit-p95-us" && i + 1 < argc) {
            if (!parse_double(argv[++i],
                              &options->config.client_exit_p95_us))
                return false;
        } else if (arg == "--dual-enter-backend-qps" && i + 1 < argc) {
            if (!parse_double(argv[++i],
                              &options->config.dual_enter_backend_qps))
                return false;
        } else if (arg == "--dual-exit-backend-qps" && i + 1 < argc) {
            if (!parse_double(argv[++i],
                              &options->config.dual_exit_backend_qps))
                return false;
        } else if (arg == "--bypass-error-rate" && i + 1 < argc) {
            if (!parse_double(argv[++i],
                              &options->config.bypass_error_rate))
                return false;
        } else if (arg == "-h" || arg == "--help") {
            return false;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return false;
        }
    }
    if (options->config.cache_exit_hit_ratio < 0.0 ||
        options->config.cache_enter_hit_ratio > 1.0 ||
        options->config.cache_exit_hit_ratio >
            options->config.cache_enter_hit_ratio ||
        options->config.client_exit_p95_us < 0.0 ||
        options->config.client_exit_p95_us >
            options->config.client_enter_p95_us ||
        options->config.dual_exit_backend_qps < 0.0 ||
        options->config.dual_exit_backend_qps >
            options->config.dual_enter_backend_qps ||
        options->config.bypass_error_rate < 0.0 ||
        options->config.bypass_error_rate > 1.0)
        return false;
    const bool has_control_maps = !options->control_maps.empty();
    const bool has_desired_mode_file = !options->desired_mode_file.empty();
    if (has_desired_mode_file &&
        (options->desired_mode_file.size() == 1 ||
         options->desired_mode_file.front() != '/' ||
         options->desired_mode_file.back() == '/'))
        return false;
    const size_t publisher_count = static_cast<size_t>(options->dry_run) +
                                   static_cast<size_t>(has_control_maps) +
                                   static_cast<size_t>(has_desired_mode_file);
    return publisher_count == 1;
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
    else if (!options.desired_mode_file.empty())
        publisher = std::make_unique<DesiredModeFilePublisher>(
            options.desired_mode_file);
    else
        publisher = std::make_unique<BpfCachePolicyPublisher>(
            options.control_maps);

    std::string publish_error;
    if (!publisher->publish(options.config.initial_mode,
                            options.startup_epoch,
                            &publish_error)) {
        std::cerr << "Failed to publish initial cache mode: "
                  << publish_error << "\n";
        return 1;
    }
    options.config.initial_epoch = options.startup_epoch;

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
        std::cout << output << "\n" << std::flush;
        if (audit) {
            audit << output << "\n";
            audit.flush();
        }
    }
    return 0;
}
