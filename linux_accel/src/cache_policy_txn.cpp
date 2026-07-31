#include "cache_runtime_control.h"
#include "cache_policy_txn_path_policy.hpp"
#include "dynamic_cache_controller.hpp"

#include <bpf/bpf.h>
#include <errno.h>
#include <linux/bpf.h>
#include <fcntl.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

enum class Operation {
    Stage,
    VerifyStaged,
    Commit,
    VerifyCommitted,
    ForceBypass,
    ReadCurrent,
};

struct Options {
    Operation operation = Operation::Stage;
    bool operation_set = false;
    CacheMode mode = CacheMode::Bypass;
    bool mode_set = false;
    uint64_t epoch = 0;
    bool allow_all_missing = false;
    std::string lock_file;
    std::string quiesce_file;
    bool quiesce_file_set = false;
    std::vector<std::string> map_paths;
};

struct OpenMap {
    std::string path;
    int fd = -1;
};

void usage(const char *program)
{
    std::cerr
        << "Usage: " << program
        << " --operation stage|verify-staged|commit|verify-committed|force-bypass|read-current"
        << " --mode bypass|server|client|dual --epoch <n>"
        << " --control-map <pinned-map>... --lock-file <path>"
        << " --quiesce-file <absolute-path>"
        << " [--allow-all-missing]\n";
}

bool parse_u64(const std::string &text, uint64_t *value)
{
    if (text.empty() || text[0] == '-')
        return false;
    errno = 0;
    char *end = nullptr;
    const unsigned long long parsed = std::strtoull(text.c_str(), &end, 10);
    if (errno == ERANGE || !end || *end != '\0' || parsed == 0)
        return false;
    *value = static_cast<uint64_t>(parsed);
    return true;
}

bool parse_operation(const std::string &text, Operation *operation)
{
    if (text == "stage")
        *operation = Operation::Stage;
    else if (text == "verify-staged")
        *operation = Operation::VerifyStaged;
    else if (text == "commit")
        *operation = Operation::Commit;
    else if (text == "verify-committed")
        *operation = Operation::VerifyCommitted;
    else if (text == "force-bypass")
        *operation = Operation::ForceBypass;
    else if (text == "read-current")
        *operation = Operation::ReadCurrent;
    else
        return false;
    return true;
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--operation" && i + 1 < argc) {
            options->operation_set =
                parse_operation(argv[++i], &options->operation);
            if (!options->operation_set)
                return false;
        } else if (argument == "--mode" && i + 1 < argc) {
            options->mode_set = parse_cache_mode(argv[++i], &options->mode);
            if (!options->mode_set)
                return false;
        } else if (argument == "--epoch" && i + 1 < argc) {
            if (!parse_u64(argv[++i], &options->epoch))
                return false;
        } else if (argument == "--control-map" && i + 1 < argc) {
            options->map_paths.emplace_back(argv[++i]);
        } else if (argument == "--allow-all-missing") {
            options->allow_all_missing = true;
        } else if (argument == "--lock-file" && i + 1 < argc) {
            options->lock_file = argv[++i];
        } else if (argument == "--quiesce-file" && i + 1 < argc) {
            if (options->quiesce_file_set)
                return false;
            options->quiesce_file = argv[++i];
            options->quiesce_file_set = true;
        } else if (argument == "-h" || argument == "--help") {
            return false;
        } else {
            return false;
        }
    }
    return options->operation_set && options->mode_set && options->epoch > 0 &&
           !options->map_paths.empty() && !options->lock_file.empty() &&
           options->quiesce_file_set &&
           (options->operation != Operation::ForceBypass ||
             options->mode == CacheMode::Bypass);
}

class ScopedLock {
public:
    ~ScopedLock()
    {
        if (fd_ >= 0)
            close(fd_);
    }

    bool acquire(const std::string &path, std::string *error)
    {
        const size_t separator = path.find_last_of('/');
        if (path.empty() || path.front() != '/' ||
            separator == std::string::npos || separator + 1 >= path.size()) {
            *error = "invalid lock path: " + path;
            return false;
        }
        const std::string parent =
            separator == 0 ? "/" : path.substr(0, separator);
        const std::string name = path.substr(separator + 1);
        if (name == "." || name == "..") {
            *error = "invalid lock name: " + path;
            return false;
        }

        struct stat parent_path_status = {};
        if (lstat(parent.c_str(), &parent_path_status) != 0) {
            *error = "inspect lock parent " + parent + ": " +
                     strerror(errno);
            return false;
        }
        if (!S_ISDIR(parent_path_status.st_mode)) {
            *error = "lock parent is not a real directory: " + parent;
            return false;
        }

        int parent_fd = open(parent.c_str(), O_RDONLY | O_DIRECTORY |
                                                O_CLOEXEC | O_NOFOLLOW);
        if (parent_fd < 0) {
            *error = "open lock parent " + parent + ": " + strerror(errno);
            return false;
        }
        auto fail = [&](std::string message) {
            if (fd_ >= 0) {
                close(fd_);
                fd_ = -1;
            }
            close(parent_fd);
            *error = std::move(message);
            return false;
        };

        struct stat parent_fd_status = {};
        if (fstat(parent_fd, &parent_fd_status) != 0) {
            const int saved_errno = errno;
            return fail("inspect opened lock parent " + parent + ": " +
                        strerror(saved_errno));
        }
        const uid_t effective_uid = geteuid();
        if (!S_ISDIR(parent_fd_status.st_mode) ||
            parent_fd_status.st_dev != parent_path_status.st_dev ||
            parent_fd_status.st_ino != parent_path_status.st_ino) {
            return fail("lock parent changed or is not a real directory: " +
                        parent);
        }
        if (parent_fd_status.st_uid != 0 &&
            parent_fd_status.st_uid != effective_uid) {
            return fail("lock parent has an untrusted owner: " + parent);
        }
        if ((parent_fd_status.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
            return fail("lock parent is writable by group or other users: " +
                        parent);
        }

        bool created = false;
        fd_ = openat(parent_fd, name.c_str(),
                     O_CREAT | O_EXCL | O_CLOEXEC | O_RDWR | O_NOFOLLOW,
                     0600);
        if (fd_ >= 0) {
            created = true;
        } else if (errno == EEXIST) {
            fd_ = openat(parent_fd, name.c_str(),
                         O_CLOEXEC | O_RDWR | O_NOFOLLOW);
        }
        if (fd_ < 0) {
            const int saved_errno = errno;
            return fail("open lock " + path + ": " +
                        strerror(saved_errno));
        }
        if (created && fchmod(fd_, 0600) != 0) {
            const int saved_errno = errno;
            return fail("secure new lock " + path + ": " +
                        strerror(saved_errno));
        }

        struct stat lock_fd_status = {};
        if (fstat(fd_, &lock_fd_status) != 0) {
            const int saved_errno = errno;
            return fail("inspect lock " + path + ": " +
                        strerror(saved_errno));
        }
        if (!S_ISREG(lock_fd_status.st_mode))
            return fail("lock is not a regular file: " + path);
        if (lock_fd_status.st_uid != effective_uid)
            return fail("lock has an untrusted owner: " + path);
        if ((lock_fd_status.st_mode & 07777) != 0600)
            return fail("lock permissions must be 0600: " + path);
        if (lock_fd_status.st_nlink != 1)
            return fail("lock must have exactly one link: " + path);

        if (flock(fd_, LOCK_EX) != 0) {
            const int saved_errno = errno;
            return fail("lock " + path + ": " + strerror(saved_errno));
        }

        struct stat locked_fd_status = {};
        if (fstat(fd_, &locked_fd_status) != 0) {
            const int saved_errno = errno;
            return fail("reinspect acquired lock " + path + ": " +
                        strerror(saved_errno));
        }
        if (!S_ISREG(locked_fd_status.st_mode))
            return fail("acquired lock is not a regular file: " + path);
        if (locked_fd_status.st_uid != effective_uid)
            return fail("acquired lock has an untrusted owner: " + path);
        if ((locked_fd_status.st_mode & 07777) != 0600)
            return fail("acquired lock permissions must be 0600: " + path);
        if (locked_fd_status.st_nlink != 1)
            return fail("acquired lock must have exactly one link: " + path);

        struct stat acquired_parent_fd_status = {};
        if (fstat(parent_fd, &acquired_parent_fd_status) != 0) {
            const int saved_errno = errno;
            return fail("reinspect acquired lock parent " + parent + ": " +
                        strerror(saved_errno));
        }
        struct stat acquired_parent_path_status = {};
        if (lstat(parent.c_str(), &acquired_parent_path_status) != 0) {
            const int saved_errno = errno;
            return fail("reinspect lock parent " + parent + ": " +
                        strerror(saved_errno));
        }
        if (!S_ISDIR(acquired_parent_fd_status.st_mode) ||
            !S_ISDIR(acquired_parent_path_status.st_mode) ||
            acquired_parent_fd_status.st_dev != parent_path_status.st_dev ||
            acquired_parent_fd_status.st_ino != parent_path_status.st_ino ||
            acquired_parent_path_status.st_dev !=
                acquired_parent_fd_status.st_dev ||
            acquired_parent_path_status.st_ino !=
                acquired_parent_fd_status.st_ino) {
            return fail("lock parent changed during acquisition: " + parent);
        }
        if (acquired_parent_fd_status.st_uid != 0 &&
            acquired_parent_fd_status.st_uid != effective_uid) {
            return fail("acquired lock parent has an untrusted owner: " +
                        parent);
        }
        if (acquired_parent_path_status.st_uid != 0 &&
            acquired_parent_path_status.st_uid != effective_uid) {
            return fail("lock parent path has an untrusted owner: " + parent);
        }
        if ((acquired_parent_fd_status.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
            (acquired_parent_path_status.st_mode &
             (S_IWGRP | S_IWOTH)) != 0) {
            return fail("acquired lock parent is writable by group or other "
                        "users: " +
                        parent);
        }

        struct stat lock_path_status = {};
        if (fstatat(parent_fd, name.c_str(), &lock_path_status,
                    AT_SYMLINK_NOFOLLOW) != 0) {
            const int saved_errno = errno;
            return fail("reinspect lock " + path + ": " +
                        strerror(saved_errno));
        }
        if (!S_ISREG(lock_path_status.st_mode))
            return fail("lock path is not a regular file: " + path);
        if (lock_path_status.st_uid != effective_uid)
            return fail("lock path has an untrusted owner: " + path);
        if ((lock_path_status.st_mode & 07777) != 0600)
            return fail("lock path permissions must be 0600: " + path);
        if (lock_path_status.st_nlink != 1)
            return fail("lock path must have exactly one link: " + path);
        if (lock_path_status.st_dev != locked_fd_status.st_dev ||
            lock_path_status.st_ino != locked_fd_status.st_ino) {
            return fail("lock path changed during acquisition: " + path);
        }

        close(parent_fd);
        return true;
    }

private:
    int fd_ = -1;
};

bool operation_requires_quiesce_clear(Operation operation)
{
    switch (operation) {
    case Operation::Stage:
    case Operation::VerifyStaged:
    case Operation::Commit:
    case Operation::VerifyCommitted:
        return true;
    case Operation::ForceBypass:
    case Operation::ReadCurrent:
        return false;
    }
    return true;
}

bool quiesce_file_is_clear(const std::string &path, std::string *error)
{
    struct stat status = {};
    if (lstat(path.c_str(), &status) == 0) {
        *error = "quiesce fence active: " + path;
        return false;
    }
    if (errno == ENOENT)
        return true;
    *error = "inspect quiesce file " + path + ": " + strerror(errno);
    return false;
}

void close_maps(std::vector<OpenMap> *maps)
{
    for (OpenMap &map : *maps) {
        if (map.fd >= 0)
            close(map.fd);
        map.fd = -1;
    }
}

bool open_maps(const Options &options, std::vector<OpenMap> *maps,
               std::string *error)
{
    size_t missing = 0;
    for (const std::string &path : options.map_paths) {
        OpenMap map;
        map.path = path;
        map.fd = bpf_obj_get(path.c_str());
        if (map.fd < 0) {
            if (options.allow_all_missing && errno == ENOENT) {
                missing++;
                continue;
            }
            *error = "open " + path + ": " + strerror(errno);
            close_maps(maps);
            return false;
        }
        bpf_map_info info = {};
        uint32_t info_len = sizeof(info);
        if (bpf_obj_get_info_by_fd(map.fd, &info, &info_len) != 0) {
            *error = "inspect " + path + ": " + strerror(errno);
            close(map.fd);
            close_maps(maps);
            return false;
        }
        if (info.type != BPF_MAP_TYPE_ARRAY ||
            info.key_size != sizeof(uint32_t) ||
            info.value_size != sizeof(cache_runtime_control) ||
            info.max_entries < 1) {
            *error = "incompatible runtime control map: " + path;
            close(map.fd);
            close_maps(maps);
            return false;
        }
        maps->push_back(std::move(map));
    }
    if (missing && !maps->empty()) {
        *error = "only some runtime control maps are missing";
        close_maps(maps);
        return false;
    }
    return true;
}

cache_runtime_control control_value(CacheMode mode, uint64_t epoch,
                                    uint32_t flags)
{
    cache_runtime_control value = {};
    value.epoch = epoch;
    value.mode = static_cast<uint32_t>(mode);
    value.flags = flags;
    return value;
}

bool write_all(const std::vector<OpenMap> &maps,
               const cache_runtime_control &value, std::string *error)
{
    const uint32_t key = 0;
    for (const OpenMap &map : maps) {
        if (bpf_map_update_elem(map.fd, &key, &value, BPF_ANY) != 0) {
            *error = "update " + map.path + ": " + strerror(errno);
            return false;
        }
    }
    return true;
}

bool verify_all(const std::vector<OpenMap> &maps,
                const cache_runtime_control &expected, std::string *error)
{
    const uint32_t key = 0;
    for (const OpenMap &map : maps) {
        cache_runtime_control observed = {};
        if (bpf_map_lookup_elem(map.fd, &key, &observed) != 0) {
            *error = "read " + map.path + ": " + strerror(errno);
            return false;
        }
        if (observed.epoch != expected.epoch ||
            observed.mode != expected.mode || observed.flags != expected.flags) {
            *error = "unexpected runtime control value: " + map.path;
            return false;
        }
    }
    return true;
}

bool read_map(const OpenMap &map, cache_runtime_control *value,
              std::string *error)
{
    const uint32_t key = 0;
    if (bpf_map_lookup_elem(map.fd, &key, value) != 0) {
        *error = "read " + map.path + ": " + strerror(errno);
        return false;
    }
    return true;
}

bool stage_allowed(const std::vector<OpenMap> &maps, CacheMode mode,
                   uint64_t epoch, std::string *error)
{
    for (const OpenMap &map : maps) {
        cache_runtime_control current = {};
        if (!read_map(map, &current, error))
            return false;
        if (current.epoch > epoch) {
            *error = "refusing epoch rollback: " + map.path;
            return false;
        }
        if (current.epoch == epoch &&
            (current.mode != static_cast<uint32_t>(mode) ||
             current.flags != 0)) {
            *error = "epoch already contains a different state: " + map.path;
            return false;
        }
    }
    return true;
}

bool bypass_epoch_allowed(const std::vector<OpenMap> &maps, uint64_t epoch,
                          std::string *error)
{
    for (const OpenMap &map : maps) {
        cache_runtime_control current = {};
        if (!read_map(map, &current, error))
            return false;
        if (current.epoch > epoch) {
            *error = "refusing BYPASS epoch rollback: " + map.path;
            return false;
        }
    }
    return true;
}

bool read_consistent(const std::vector<OpenMap> &maps,
                     cache_runtime_control *value, std::string *error)
{
    if (maps.empty())
        return true;
    if (!read_map(maps.front(), value, error))
        return false;
    for (size_t index = 1; index < maps.size(); ++index) {
        cache_runtime_control current = {};
        if (!read_map(maps[index], &current, error))
            return false;
        if (current.epoch != value->epoch || current.mode != value->mode ||
            current.flags != value->flags) {
            *error = "runtime control maps disagree";
            return false;
        }
    }
    return true;
}

void best_effort_bypass(const std::vector<OpenMap> &maps, uint64_t epoch)
{
    const uint32_t key = 0;
    for (const OpenMap &map : maps) {
        cache_runtime_control current = {};
        uint64_t safe_epoch = epoch;
        if (bpf_map_lookup_elem(map.fd, &key, &current) == 0 &&
            current.epoch > safe_epoch)
            safe_epoch = current.epoch;
        const cache_runtime_control bypass = control_value(
            CacheMode::Bypass, safe_epoch, CACHE_RUNTIME_COMMITTED);
        bpf_map_update_elem(map.fd, &key, &bypass, BPF_ANY);
    }
}

bool execute(const Options &options, const std::vector<OpenMap> &maps,
             std::string *error)
{
    const cache_runtime_control staged =
        control_value(options.mode, options.epoch, 0);
    const cache_runtime_control committed =
        control_value(options.mode, options.epoch, CACHE_RUNTIME_COMMITTED);
    switch (options.operation) {
    case Operation::Stage:
        if (!stage_allowed(maps, options.mode, options.epoch, error) ||
            !write_all(maps, staged, error) ||
            !verify_all(maps, staged, error)) {
            best_effort_bypass(maps, options.epoch);
            return false;
        }
        return true;
    case Operation::VerifyStaged:
        return verify_all(maps, staged, error);
    case Operation::Commit:
        if (!verify_all(maps, staged, error) ||
            !write_all(maps, committed, error) ||
            !verify_all(maps, committed, error)) {
            best_effort_bypass(maps, options.epoch);
            return false;
        }
        return true;
    case Operation::VerifyCommitted:
        return verify_all(maps, committed, error);
    case Operation::ForceBypass: {
        // Same-epoch BYPASS is the terminal recovery fence. A delayed commit
        // still requires its exact staged value and therefore cannot undo it.
        const cache_runtime_control bypass_staged =
            control_value(CacheMode::Bypass, options.epoch, 0);
        const cache_runtime_control bypass_committed =
            control_value(CacheMode::Bypass, options.epoch,
                          CACHE_RUNTIME_COMMITTED);
        if (!bypass_epoch_allowed(maps, options.epoch, error) ||
            !write_all(maps, bypass_staged, error) ||
            !verify_all(maps, bypass_staged, error) ||
            !write_all(maps, bypass_committed, error) ||
            !verify_all(maps, bypass_committed, error)) {
            best_effort_bypass(maps, options.epoch);
            return false;
        }
        return true;
    }
    case Operation::ReadCurrent:
        *error = "read-current is handled separately";
        return false;
    }
    *error = "unsupported operation";
    return false;
}

const char *operation_name(Operation operation)
{
    switch (operation) {
    case Operation::Stage:
        return "stage";
    case Operation::VerifyStaged:
        return "verify-staged";
    case Operation::Commit:
        return "commit";
    case Operation::VerifyCommitted:
        return "verify-committed";
    case Operation::ForceBypass:
        return "force-bypass";
    case Operation::ReadCurrent:
        return "read-current";
    }
    return "unknown";
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) {
        usage(argv[0]);
        return 1;
    }

    std::string error;
    if (!cache_policy_txn::validate_production_paths(
            options.lock_file, options.quiesce_file, options.map_paths,
            &error)) {
        std::cerr << "cache_policy_txn: " << error << "\n";
        return 1;
    }

    ScopedLock lock;
    if (!lock.acquire(options.lock_file, &error)) {
        std::cerr << "cache_policy_txn: " << error << "\n";
        return 1;
    }

    std::vector<OpenMap> maps;
    if (!open_maps(options, &maps, &error)) {
        std::cerr << "cache_policy_txn: " << error << "\n";
        return 1;
    }

    // Hold the endpoint lock while validating maps, then fence only real map
    // operations. An all-missing allow-all-missing request stays a no-op.
    if (operation_requires_quiesce_clear(options.operation) && !maps.empty() &&
        !quiesce_file_is_clear(options.quiesce_file, &error)) {
        close_maps(&maps);
        std::cerr << "cache_policy_txn: " << error << "\n";
        return 1;
    }
    if (options.operation == Operation::ReadCurrent) {
        cache_runtime_control current = {};
        const bool ok = read_consistent(maps, &current, &error);
        const size_t opened_maps = maps.size();
        close_maps(&maps);
        if (!ok) {
            std::cerr << "cache_policy_txn: " << error << "\n";
            return 1;
        }
        std::cout << "{\"schema_version\":1,\"present\":"
                  << (opened_maps ? "true" : "false")
                  << ",\"maps\":" << opened_maps
                  << ",\"epoch\":" << current.epoch
                  << ",\"mode\":" << current.mode
                  << ",\"flags\":" << current.flags << "}\n";
        return 0;
    }

    const bool ok = execute(options, maps, &error);
    const size_t opened_maps = maps.size();
    close_maps(&maps);
    if (!ok) {
        std::cerr << "cache_policy_txn: " << error << "\n";
        return 1;
    }
    std::cout << "cache_policy_txn operation="
              << operation_name(options.operation)
              << " mode=" << cache_mode_name(options.mode)
              << " epoch=" << options.epoch
              << " maps=" << opened_maps
              << " configured_maps=" << options.map_paths.size() << "\n";
    return 0;
}
