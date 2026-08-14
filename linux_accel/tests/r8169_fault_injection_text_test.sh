#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
readonly script_dir repo_dir

readonly patch_dir="${repo_dir}/patches/r8169-native-xdp"
readonly fault_patch="${patch_dir}/0004-ubuntu-trial-fault-injection.patch"
readonly base_patch="${patch_dir}/0001-r8169-add-native-xdp-support.patch"
readonly prepare_script="${repo_dir}/driver/r8169-xdp/prepare_ubuntu_7_0_module.sh"
readonly build_script="${repo_dir}/driver/r8169-xdp/build_ubuntu_7_0_module.sh"
readonly trial_script="${repo_dir}/driver/r8169-xdp/local_console_trial.sh"
readonly prepared_main_sha256="5db2f895aa66106f8557a4f87a44b22b59fbf5b0514dab98b564833024c9b26c"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_fixed() {
  local needle="$1"
  local file="$2"
  local description="$3"

  rg --fixed-strings --quiet -- "${needle}" "${file}" || fail "${description}"
}

forbid_regex() {
  local pattern="$1"
  local file="$2"
  local description="$3"

  if rg --quiet -- "${pattern}" "${file}"; then
    fail "${description}"
  fi
}

for command_name in awk bash mktemp rg sed; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    fail "missing command: ${command_name}"
done

[[ -f "${fault_patch}" ]] || fail "0004 fault-injection patch is missing"

added_source="$(mktemp "${TMPDIR:-/tmp}/r8169-fi-added.XXXXXX")"
cleanup() {
  rm -f -- "${added_source}"
}
trap cleanup EXIT INT TERM
sed -n 's/^+//p' "${fault_patch}" > "${added_source}"

require_fixed 'Subject: [PATCH 1/4]' \
  "${patch_dir}/0001-r8169-add-native-xdp-support.patch" \
  "0001 is not numbered as part of the four-patch series"
require_fixed 'Subject: [PATCH 2/4]' \
  "${patch_dir}/0002-ubuntu-7.0-netdev-lock-compat.patch" \
  "0002 is not numbered as part of the four-patch series"
require_fixed 'Subject: [PATCH 3/4]' \
  "${patch_dir}/0003-ubuntu-trial-require-pci-bdf.patch" \
  "0003 is not numbered as part of the four-patch series"
require_fixed 'Subject: [PATCH 4/4]' "${fault_patch}" \
  "0004 is not numbered as the final patch"

require_fixed \
  'module_param_named(fault_injection, fault_injection, bool, 0400);' \
  "${added_source}" "fault_injection is not a read-only load-time parameter"
require_fixed 'static atomic_t fi_tx_full_once = ATOMIC_INIT(0);' \
  "${added_source}" "TX-full budget is not atomically initialized to zero"
require_fixed 'static atomic_t fi_rx_refill_once = ATOMIC_INIT(0);' \
  "${added_source}" "RX-refill budget is not atomically initialized to zero"
require_fixed 'module_param_cb(fi_tx_full_once, &rtl8169_fault_budget_ops,' \
  "${added_source}" "TX-full budget lacks the guarded parameter callback"
require_fixed 'module_param_cb(fi_rx_refill_once, &rtl8169_fault_budget_ops,' \
  "${added_source}" "RX-refill budget lacks the guarded parameter callback"
[[ "$(rg --count --fixed-strings -- '&fi_tx_full_once, 0600);' "${added_source}")" == "1" ]] ||
  fail "TX-full budget is not root-only 0600"
[[ "$(rg --count --fixed-strings -- '&fi_rx_refill_once, 0600);' "${added_source}")" == "1" ]] ||
  fail "RX-refill budget is not root-only 0600"
require_fixed 'if (budget > 1)' "${added_source}" \
  "budget setter does not restrict values to zero or one"
require_fixed 'if (budget && !READ_ONCE(fault_injection))' "${added_source}" \
  "budget setter does not reject arming while the master is disabled"
require_fixed 'atomic_cmpxchg(budget, 1, 0) == 1' "${added_source}" \
  "budget consumption is not atomic and exactly once"

for counter in RTL_XDP_STAT_FI_TX_FULL RTL_XDP_STAT_FI_RX_REFILL; do
  require_fixed "${counter}" "${added_source}" \
    "dedicated fault-injection counter ${counter} is absent"
done
for counter_name in xdp_fi_tx_full xdp_fi_rx_refill; do
  require_fixed "\"${counter_name}\"" "${added_source}" \
    "ethtool string ${counter_name} is absent"
done
[[ "$(rg --count --fixed-strings -- 'trial fault injection: forced one' "${added_source}")" == "2" ]] ||
  fail "fault injection must have exactly two controlled warning sites"
require_fixed 'goto err_unlock;' "${added_source}" \
  "synthetic TX-full does not use the existing unlock failure label"
require_fixed 'if (replacement) {' "${fault_patch}" \
  "synthetic refill failure does not rejoin the existing replacement branch"
require_fixed 'page_pool_recycle_direct(tp->page_pool, replacement);' \
  "${base_patch}" "base TX failure path no longer recycles the replacement"
require_fixed 'goto xdp_exception;' "${base_patch}" \
  "base refill/TX failure path no longer enters XDP exception cleanup"
forbid_regex 'fail_page_alloc|should_fail|debugfs' "${fault_patch}" \
  "0004 must not use a global or debugfs fault-injection mechanism"

guard_apply_line="$(rg -n --fixed-strings -- '< "${trial_guard_patch}"' \
  "${prepare_script}" | awk -F: 'END { print $1 }')"
fault_apply_line="$(rg -n --fixed-strings -- '< "${fault_injection_patch}"' \
  "${prepare_script}" | awk -F: 'END { print $1 }')"
[[ -n "${guard_apply_line}" && -n "${fault_apply_line}" ]] ||
  fail "prepare script does not apply both trial patches"
(( fault_apply_line > guard_apply_line )) ||
  fail "prepare script must apply 0004 after 0003"
require_fixed \
  "fault_injection_patch=\$(basename \"\${fault_injection_patch}\")" \
  "${prepare_script}" "BUILD-BASELINE omits the fault-injection patch"
require_fixed \
  'fault_injection_patch=0004-ubuntu-trial-fault-injection.patch' \
  "${build_script}" "build script does not pin the 0004 baseline marker"
require_fixed "${prepared_main_sha256}" "${prepare_script}" \
  "prepare script has the wrong final r8169_main.c hash"
require_fixed "${prepared_main_sha256}" "${build_script}" \
  "build script has the wrong final r8169_main.c hash"

require_fixed 'readonly -a preserved_services=(kubelet.service)' \
  "${trial_script}" "kubelet preserve-state protection was removed"
require_fixed "sysfs_write 0 \"\${path}\"" "${trial_script}" \
  "rollback does not clear one-shot fault budgets"
require_fixed 'verify_loaded_fault_injection_controls' "${trial_script}" \
  "trial script does not verify loaded control values and permissions"
require_fixed "\"fault_injection=\${enable_fault_injection}\"" "${trial_script}" \
  "trial module load does not explicitly set the read-only master"

clear_line="$(rg -n --fixed-strings -- 'if ! clear_fault_injection_budgets; then' \
  "${trial_script}" | awk -F: 'NR == 1 { print $1 }')"
driver_read_line="$(awk -v start="${clear_line}" \
  'NR > start && /active_driver="\$\(current_driver\)"/ { print NR; exit }' \
  "${trial_script}")"
unbind_line="$(awk -v start="${clear_line}" \
  'NR > start && /r8169_xdp\/unbind/ { print NR; exit }' "${trial_script}")"
[[ -n "${clear_line}" && -n "${driver_read_line}" && -n "${unbind_line}" ]] ||
  fail "cannot establish rollback ordering"
(( clear_line < driver_read_line && clear_line < unbind_line )) ||
  fail "rollback must clear budgets before inspecting or unbinding the driver"

bash -n "${prepare_script}"
bash -n "${build_script}"
bash -n "${trial_script}"
bash -n "${BASH_SOURCE[0]}"

echo "PASS: r8169 trial-only fault-injection static contract"
