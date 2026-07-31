#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
controller="${1:-${root_dir}/build/dynamic_cache_controller}"
test_dir="$(mktemp -d /tmp/vnet-dynamic-cache-desired-mode.XXXXXX)"
desired_file="${test_dir}/desired-mode.json"
metrics_fifo="${test_dir}/metrics.fifo"
controller_pid=

if [[ ! -x "${controller}" ]]; then
  echo "dynamic_cache_desired_mode_test: missing controller: ${controller}" >&2
  exit 1
fi
command -v find >/dev/null
command -v cc >/dev/null
command -v mkfifo >/dev/null
command -v python3 >/dev/null
command -v stat >/dev/null

cleanup() {
  local status=$?

  trap - EXIT
  if [[ -n "${controller_pid}" ]]; then
    if kill -0 "${controller_pid}" 2>/dev/null; then
      kill "${controller_pid}" 2>/dev/null || true
    fi
    wait "${controller_pid}" 2>/dev/null || true
  fi
  case "${test_dir}" in
    /tmp/vnet-dynamic-cache-desired-mode.*)
      if [[ "${status}" -eq 0 ]]; then
        rm -rf -- "${test_dir}"
      else
        echo "dynamic_cache_desired_mode_test: preserved artifacts: ${test_dir}" >&2
      fi
      ;;
    *)
      echo "dynamic_cache_desired_mode_test: unsafe cleanup path" >&2
      status=1
      ;;
  esac
  exit "${status}"
}
trap cleanup EXIT

assert_desired_mode() {
  local expected_mode="$1"

  python3 - "${desired_file}" "${expected_mode}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
expected = {"schema_version": 1, "mode": sys.argv[2]}
try:
    observed = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(
        f"dynamic_cache_desired_mode_test: invalid desired file: {error}"
    )
if observed != expected:
    raise SystemExit(
        "dynamic_cache_desired_mode_test: unexpected desired JSON: "
        f"{observed!r}"
    )
PY
}

assert_no_publication_artifacts() {
  if [[ -n "$(find "${test_dir}" -maxdepth 1 \
    \( -name 'desired-mode.json.tmp.*' \
    -o -name 'desired-mode.json.rollback.*' \) -print -quit)" ]]; then
    echo "dynamic_cache_desired_mode_test: publication artifact remains" >&2
    exit 1
  fi
}

expect_rejected() {
  local description="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    echo "dynamic_cache_desired_mode_test: accepted ${description}" >&2
    exit 1
  fi
}

fsync_fault_source="${test_dir}/fsync-after-rename-fault.c"
fsync_fault_library="${test_dir}/fsync-after-rename-fault.so"
cat >"${fsync_fault_source}" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static int (*real_fsync)(int);
static int (*real_rename)(const char *, const char *);
static atomic_int directory_sync_armed;
static atomic_int fsync_fault_initialized;
static atomic_int remaining_fsync_faults;
static atomic_int close_fault_armed;
static atomic_int directory_sync_completed;
static atomic_int close_fault_injected;
static atomic_int target_rename_count;

static int target_parent_matches(int fd, const char *target)
{
    struct stat directory_status;
    struct stat target_status;
    char parent[PATH_MAX];
    char *separator;
    size_t length;

    if (!target)
        return 0;
    length = strlen(target);
    if (length == 0 || length >= sizeof(parent))
        return 0;
    memcpy(parent, target, length + 1);
    separator = strrchr(parent, '/');
    if (!separator)
        strcpy(parent, ".");
    else if (separator == parent)
        separator[1] = '\0';
    else
        *separator = '\0';
    return fstat(fd, &directory_status) == 0 &&
           stat(parent, &target_status) == 0 &&
           S_ISDIR(directory_status.st_mode) &&
           directory_status.st_dev == target_status.st_dev &&
           directory_status.st_ino == target_status.st_ino;
}

static void resolve_functions(void)
{
    if (!real_fsync)
        real_fsync = dlsym(RTLD_NEXT, "fsync");
    if (!real_rename)
        real_rename = dlsym(RTLD_NEXT, "rename");
}

int rename(const char *old_path, const char *new_path)
{
    const char *close_target;
    const char *failure_count_text;
    const char *fsync_target;
    const char *replacement_rename_fault;
    const char *rollback_rename_fault;
    long failure_count;
    int result;
    int target_rename_index = 0;

    resolve_functions();
    fsync_target = getenv("VNET_TEST_FSYNC_FAIL_AFTER_RENAME");
    replacement_rename_fault =
        getenv("VNET_TEST_REPLACEMENT_RENAME_EIO");
    rollback_rename_fault = getenv("VNET_TEST_ROLLBACK_RENAME_EIO");
    if (fsync_target && strcmp(new_path, fsync_target) == 0)
        target_rename_index = atomic_fetch_add(&target_rename_count, 1) + 1;
    if (target_rename_index == 1 && replacement_rename_fault &&
        strcmp(replacement_rename_fault, "before") == 0) {
        errno = EIO;
        return -1;
    }
    if (target_rename_index == 2 && rollback_rename_fault &&
        strcmp(rollback_rename_fault, "before") == 0) {
        errno = EIO;
        return -1;
    }
    result = real_rename(old_path, new_path);
    if (result == 0 && target_rename_index == 1 &&
        replacement_rename_fault &&
        strcmp(replacement_rename_fault, "after") == 0) {
        errno = EIO;
        return -1;
    }
    if (result == 0 && target_rename_index == 2 && rollback_rename_fault &&
        strcmp(rollback_rename_fault, "after") == 0) {
        errno = EIO;
        return -1;
    }
    close_target = getenv("VNET_TEST_CLOSE_FAIL_AFTER_RENAME");
    if (result == 0 && fsync_target &&
        strcmp(new_path, fsync_target) == 0 &&
        atomic_exchange(&fsync_fault_initialized, 1) == 0) {
        failure_count_text = getenv("VNET_TEST_FSYNC_FAILURE_COUNT");
        failure_count = failure_count_text ? strtol(failure_count_text, 0, 10)
                                           : 1;
        if (failure_count < 1)
            failure_count = 1;
        if (failure_count > INT_MAX)
            failure_count = INT_MAX;
        atomic_store(&remaining_fsync_faults, (int)failure_count);
        atomic_store(&directory_sync_armed, 1);
    }
    if (result == 0 && close_target &&
        strcmp(new_path, close_target) == 0 &&
        atomic_load(&close_fault_injected) == 0)
        atomic_store(&close_fault_armed, 1);
    return result;
}

int fsync(int fd)
{
    const char *close_target;
    const char *fsync_target;
    int result;

    resolve_functions();
    fsync_target = getenv("VNET_TEST_FSYNC_FAIL_AFTER_RENAME");
    close_target = getenv("VNET_TEST_CLOSE_FAIL_AFTER_RENAME");
    if (atomic_load(&directory_sync_armed) != 0 &&
        target_parent_matches(fd, fsync_target) &&
        atomic_fetch_sub(&remaining_fsync_faults, 1) > 0) {
        if (atomic_load(&remaining_fsync_faults) == 0)
            atomic_store(&directory_sync_armed, 0);
        errno = EIO;
        return -1;
    }
    result = real_fsync(fd);
    if (result == 0 && atomic_load(&close_fault_armed) != 0 &&
        target_parent_matches(fd, close_target))
        atomic_store(&directory_sync_completed, 1);
    return result;
}

int close(int fd)
{
    const char *target;
    int is_target_directory;
    int result;

    target = getenv("VNET_TEST_CLOSE_FAIL_AFTER_RENAME");
    is_target_directory = target_parent_matches(fd, target);
    result = syscall(SYS_close, fd);
    if (result == 0 && is_target_directory &&
        atomic_load(&close_fault_armed) != 0 &&
        atomic_load(&directory_sync_completed) != 0 &&
        atomic_exchange(&close_fault_injected, 1) == 0) {
        errno = EIO;
        return -1;
    }
    return result;
}
EOF
cc -std=c11 -O2 -fPIC -shared "${fsync_fault_source}" \
  -o "${fsync_fault_library}" -ldl

expect_publish_sync_failure() {
  local initial_mode="$1"
  local log_path="$2"

  if VNET_TEST_FSYNC_FAIL_AFTER_RENAME="${desired_file}" \
    LD_PRELOAD="${fsync_fault_library}" \
    "${controller}" --desired-mode-file "${desired_file}" \
    --initial-mode "${initial_mode}" </dev/null \
    >"${test_dir}/${initial_mode}-fault.stdout" 2>"${log_path}"; then
    echo "dynamic_cache_desired_mode_test: accepted failed directory sync" >&2
    exit 1
  fi
  if [[ "$(<"${log_path}")" != \
    *"Failed to publish initial cache mode: sync desired mode directory"* ]]; then
    echo "dynamic_cache_desired_mode_test: missing directory sync failure" >&2
    exit 1
  fi
}

expect_rejected "desired file with dry run" \
  "${controller}" --desired-mode-file "${desired_file}" --dry-run
expect_rejected "desired file with control map" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --control-map /sys/fs/bpf/vnet-invalid-control-map
expect_rejected "relative desired file" \
  "${controller}" --desired-mode-file desired-mode.json
expect_rejected "duplicate desired file" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --desired-mode-file "${test_dir}/second-desired-mode.json"
failed_target="${test_dir}/desired-directory"
mkdir "${failed_target}"
failed_publish_log="${test_dir}/failed-publish.stderr"
if "${controller}" --desired-mode-file "${failed_target}" \
  >/dev/null 2>"${failed_publish_log}"; then
  echo "dynamic_cache_desired_mode_test: accepted desired directory" >&2
  exit 1
fi
if [[ "$(<"${failed_publish_log}")" != \
  *"Failed to publish initial cache mode: replace desired mode"* ]]; then
  echo "dynamic_cache_desired_mode_test: missing publish failure detail" >&2
  exit 1
fi
if [[ -n "$(find "${test_dir}" -maxdepth 1 -type f \
  -name 'desired-directory.tmp.*' -print -quit)" ]]; then
  echo "dynamic_cache_desired_mode_test: failed publish left a temporary file" >&2
  exit 1
fi

printf '%s\n' '{"schema_version":1,"mode":"server"}' >"${desired_file}"
previous_inode="$(stat -c '%i' "${desired_file}")"
expect_publish_sync_failure client "${test_dir}/existing-fsync-failure.stderr"
assert_desired_mode server
restored_inode="$(stat -c '%i' "${desired_file}")"
if [[ "${previous_inode}" != "${restored_inode}" ]]; then
  echo "dynamic_cache_desired_mode_test: previous desired inode was not restored" >&2
  exit 1
fi
assert_no_publication_artifacts

rm -- "${desired_file}"
expect_publish_sync_failure dual "${test_dir}/absent-fsync-failure.stderr"
if [[ -e "${desired_file}" ]]; then
  echo "dynamic_cache_desired_mode_test: failed first publish remained visible" >&2
  exit 1
fi
assert_no_publication_artifacts

printf '%s\n' '{"schema_version":1,"mode":"server"}' >"${desired_file}"
replacement_before_old_inode="$(stat -c '%i' "${desired_file}")"
if VNET_TEST_FSYNC_FAIL_AFTER_RENAME="${desired_file}" \
  VNET_TEST_REPLACEMENT_RENAME_EIO=before \
  LD_PRELOAD="${fsync_fault_library}" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --initial-mode client </dev/null \
  >"${test_dir}/replacement-before-existing.stdout" \
  2>"${test_dir}/replacement-before-existing.stderr"; then
  echo "dynamic_cache_desired_mode_test: accepted rejected replacement" >&2
  exit 1
fi
assert_desired_mode server
if [[ "${replacement_before_old_inode}" != \
  "$(stat -c '%i' "${desired_file}")" ]]; then
  echo "dynamic_cache_desired_mode_test: failed rename replaced old inode" >&2
  exit 1
fi
assert_no_publication_artifacts

rm -- "${desired_file}"
if VNET_TEST_FSYNC_FAIL_AFTER_RENAME="${desired_file}" \
  VNET_TEST_REPLACEMENT_RENAME_EIO=before \
  LD_PRELOAD="${fsync_fault_library}" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --initial-mode dual </dev/null \
  >"${test_dir}/replacement-before-absent.stdout" \
  2>"${test_dir}/replacement-before-absent.stderr"; then
  echo "dynamic_cache_desired_mode_test: accepted absent rejected replacement" >&2
  exit 1
fi
if [[ -e "${desired_file}" ]]; then
  echo "dynamic_cache_desired_mode_test: failed first rename became visible" >&2
  exit 1
fi
assert_no_publication_artifacts

printf '%s\n' '{"schema_version":1,"mode":"server"}' >"${desired_file}"
replacement_after_old_inode="$(stat -c '%i' "${desired_file}")"
if ! VNET_TEST_FSYNC_FAIL_AFTER_RENAME="${desired_file}" \
  VNET_TEST_REPLACEMENT_RENAME_EIO=after \
  LD_PRELOAD="${fsync_fault_library}" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --initial-mode client </dev/null \
  >"${test_dir}/replacement-after-existing.stdout" \
  2>"${test_dir}/replacement-after-existing.stderr"; then
  echo "dynamic_cache_desired_mode_test: rejected visible replacement EIO" >&2
  exit 1
fi
if [[ "$(<"${test_dir}/replacement-after-existing.stderr")" != \
  *"replacement verified and committed"* ]]; then
  echo "dynamic_cache_desired_mode_test: replacement EIO was not verified" >&2
  exit 1
fi
assert_desired_mode client
if [[ "${replacement_after_old_inode}" == \
  "$(stat -c '%i' "${desired_file}")" ]]; then
  echo "dynamic_cache_desired_mode_test: replacement EIO kept old inode" >&2
  exit 1
fi
assert_no_publication_artifacts

rm -- "${desired_file}"
if ! VNET_TEST_FSYNC_FAIL_AFTER_RENAME="${desired_file}" \
  VNET_TEST_REPLACEMENT_RENAME_EIO=after \
  LD_PRELOAD="${fsync_fault_library}" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --initial-mode dual </dev/null \
  >"${test_dir}/replacement-after-absent.stdout" \
  2>"${test_dir}/replacement-after-absent.stderr"; then
  echo "dynamic_cache_desired_mode_test: rejected first visible replacement EIO" >&2
  exit 1
fi
assert_desired_mode dual
assert_no_publication_artifacts

printf '%s\n' '{"schema_version":1,"mode":"server"}' >"${desired_file}"
pseudo_failed_rollback_inode="$(stat -c '%i' "${desired_file}")"
if VNET_TEST_FSYNC_FAIL_AFTER_RENAME="${desired_file}" \
  VNET_TEST_ROLLBACK_RENAME_EIO=after LD_PRELOAD="${fsync_fault_library}" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --initial-mode client </dev/null \
  >"${test_dir}/rollback-after-eio.stdout" \
  2>"${test_dir}/rollback-after-eio.stderr"; then
  echo "dynamic_cache_desired_mode_test: missed completed rollback after EIO" >&2
  exit 1
fi
if [[ "$(<"${test_dir}/rollback-after-eio.stderr")" != \
  *"previous desired mode is visible"* ]]; then
  echo "dynamic_cache_desired_mode_test: completed rollback not identified" >&2
  exit 1
fi
assert_desired_mode server
if [[ "${pseudo_failed_rollback_inode}" != \
  "$(stat -c '%i' "${desired_file}")" ]]; then
  echo "dynamic_cache_desired_mode_test: EIO rollback lost old inode" >&2
  exit 1
fi
assert_no_publication_artifacts

printf '%s\n' '{"schema_version":1,"mode":"server"}' >"${desired_file}"
rollback_before_old_inode="$(stat -c '%i' "${desired_file}")"
if ! VNET_TEST_FSYNC_FAIL_AFTER_RENAME="${desired_file}" \
  VNET_TEST_ROLLBACK_RENAME_EIO=before LD_PRELOAD="${fsync_fault_library}" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --initial-mode client </dev/null \
  >"${test_dir}/rollback-before-eio.stdout" \
  2>"${test_dir}/rollback-before-eio.stderr"; then
  echo "dynamic_cache_desired_mode_test: rejected visible replacement" >&2
  exit 1
fi
if [[ "$(<"${test_dir}/rollback-before-eio.stderr")" != \
  *"replacement verified and committed"* ]]; then
  echo "dynamic_cache_desired_mode_test: replacement was not verified" >&2
  exit 1
fi
assert_desired_mode client
if [[ "${rollback_before_old_inode}" == \
  "$(stat -c '%i' "${desired_file}")" ]]; then
  echo "dynamic_cache_desired_mode_test: rollback-before kept old inode" >&2
  exit 1
fi
assert_no_publication_artifacts

printf '%s\n' '{"schema_version":1,"mode":"server"}' >"${desired_file}"
persistent_failure_inode="$(stat -c '%i' "${desired_file}")"
if VNET_TEST_FSYNC_FAIL_AFTER_RENAME="${desired_file}" \
  VNET_TEST_FSYNC_FAILURE_COUNT=2 LD_PRELOAD="${fsync_fault_library}" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --initial-mode client </dev/null \
  >"${test_dir}/persistent-fsync.stdout" \
  2>"${test_dir}/persistent-fsync.stderr"; then
  echo "dynamic_cache_desired_mode_test: accepted indeterminate rollback" >&2
  exit 1
fi
if [[ "$(<"${test_dir}/persistent-fsync.stderr")" != \
  *"Fatal: desired mode rollback directory sync failed"* ]]; then
  echo "dynamic_cache_desired_mode_test: rollback uncertainty not reported" >&2
  exit 1
fi
assert_desired_mode server
if [[ "${persistent_failure_inode}" != "$(stat -c '%i' "${desired_file}")" ]]; then
  echo "dynamic_cache_desired_mode_test: persistent fault lost old inode" >&2
  exit 1
fi
assert_no_publication_artifacts

printf '%s\n' '{"schema_version":1,"mode":"server"}' >"${desired_file}"
close_failure_old_inode="$(stat -c '%i' "${desired_file}")"
if ! VNET_TEST_CLOSE_FAIL_AFTER_RENAME="${desired_file}" \
  LD_PRELOAD="${fsync_fault_library}" \
  "${controller}" --desired-mode-file "${desired_file}" \
  --initial-mode client </dev/null \
  >"${test_dir}/close-fault.stdout" 2>"${test_dir}/close-fault.stderr"; then
  echo "dynamic_cache_desired_mode_test: close failure split committed state" >&2
  exit 1
fi
if [[ "$(<"${test_dir}/close-fault.stderr")" != \
  *"close desired mode directory"* ]]; then
  echo "dynamic_cache_desired_mode_test: directory close fault was not observed" >&2
  exit 1
fi
assert_desired_mode client
close_failure_new_inode="$(stat -c '%i' "${desired_file}")"
if [[ "${close_failure_old_inode}" == "${close_failure_new_inode}" ]]; then
  echo "dynamic_cache_desired_mode_test: close fault did not publish atomically" >&2
  exit 1
fi
assert_no_publication_artifacts

mkfifo "${metrics_fifo}"
"${controller}" --desired-mode-file "${desired_file}" \
  --metrics-file "${metrics_fifo}" --initial-mode bypass --initial-epoch 37 \
  --window-size 1 --required-windows 1 --cooldown-ms 0 \
  --min-window-requests 1 --cache-enter-hit-ratio 0.50 \
  >"${test_dir}/controller.stdout" 2>"${test_dir}/controller.stderr" &
controller_pid=$!

for ((attempt = 0; attempt < 100; ++attempt)); do
  [[ -f "${desired_file}" ]] && break
  if ! kill -0 "${controller_pid}" 2>/dev/null; then
    if ! wait "${controller_pid}"; then
      controller_pid=
      echo "dynamic_cache_desired_mode_test: controller initial publish failed" >&2
      exit 1
    fi
    controller_pid=
    echo "dynamic_cache_desired_mode_test: controller exited before initial write" >&2
    exit 1
  fi
  sleep 0.02
done
if [[ ! -f "${desired_file}" ]]; then
  echo "dynamic_cache_desired_mode_test: initial desired file was not written" >&2
  exit 1
fi
if ! kill -0 "${controller_pid}" 2>/dev/null; then
  wait "${controller_pid}" || true
  controller_pid=
  echo "dynamic_cache_desired_mode_test: controller exited before input" >&2
  exit 1
fi
assert_desired_mode bypass
initial_inode="$(stat -c '%i' "${desired_file}")"
assert_no_publication_artifacts

printf '%s\n' \
  'timestamp_ms,dns_hits,dns_misses,dns_p95_us,grpc_hits,grpc_misses,grpc_p95_us,backend_qps,error_rate' \
  '1000,9,1,100,0,0,0,100,0' > "${metrics_fifo}"
wait "${controller_pid}"
controller_pid=

assert_desired_mode server
final_inode="$(stat -c '%i' "${desired_file}")"
if [[ "${initial_inode}" == "${final_inode}" ]]; then
  echo "dynamic_cache_desired_mode_test: desired file was not atomically replaced" >&2
  exit 1
fi
assert_no_publication_artifacts

echo "dynamic_cache_desired_mode_test: PASS initial=bypass final=server"
