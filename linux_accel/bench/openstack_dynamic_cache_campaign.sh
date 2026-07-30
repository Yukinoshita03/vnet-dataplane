#!/usr/bin/env bash
set -euo pipefail

accel_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:?OUT_DIR is required}"
client_ip="${CLIENT_IP:?CLIENT_IP is required}"
backend_ip="${BACKEND_IP:?BACKEND_IP is required}"
client_tap="${CLIENT_TAP:?CLIENT_TAP is required}"
netns="${NETNS:-codex-campaign-probe}"
guest_key="${GUEST_KEY:?GUEST_KEY is required}"
guest_user="${GUEST_USER:-ubuntu}"
sudo_password="${SUDO_PASS:-}"
rounds="${ROUNDS:-5}"
windows="${WINDOWS:-5}"
requests_per_window="${REQUESTS_PER_WINDOW:-200}"
warmup="${WARMUP:-20}"
burst_clients="${BURST_CLIENTS:-4}"
policy_set="${POLICIES:-bypass server client dual dynamic}"
workload_set="${WORKLOADS:-stable burst hot-key shifting-hot-key low-hit-rate}"
require_netmig_tc="${REQUIRE_NETMIG_TC:-1}"
require_openstack_evidence="${REQUIRE_OPENSTACK_EVIDENCE:-1}"
openstack_openrc="${OPENSTACK_OPENRC:-}"
openstack_openrc_user="${OPENSTACK_OPENRC_USER:-admin}"
openstack_openrc_project="${OPENSTACK_OPENRC_PROJECT:-admin}"
manage_grpc_security_group_rule="${MANAGE_GRPC_SECURITY_GROUP_RULE:-0}"
openstack_grpc_backend_security_group_id="${OPENSTACK_GRPC_BACKEND_SECURITY_GROUP_ID:-}"
source_revision="${SOURCE_REVISION:-unknown}"
domain="${DOMAIN:-dynamic.test}"
answer_ip="${ANSWER_IP:-10.0.0.123}"
method="/grpc.health.v1.Health/Check"
grpc_payload="demo"
grpc_shift_payload="shift"

dns_harness="${DNS_HARNESS:?DNS_HARNESS is required}"
grpc_harness="${GRPC_HARNESS:?GRPC_HARNESS is required}"
grpc_cache="${GRPC_CACHE:?GRPC_CACHE is required}"
cachectl="${CACHECTL:?CACHECTL is required}"

dns_monitor="${accel_dir}/build/dns_monitor"
dns_client_bpf="${accel_dir}/build/dns_client_cache.bpf.o"
dns_server_bpf="${accel_dir}/build/dns_xdp_monitor.bpf.o"
grpc_monitor="${accel_dir}/build/grpc_monitor"
grpc_bpf="${accel_dir}/build/grpc_monitor.bpf.o"
controller="${accel_dir}/build/dynamic_cache_controller"
stats_reader="${accel_dir}/build/dns_cache_stats_reader"

run_token="$(printf '%s' "${RUN_TOKEN:-dynamic-$(date +%Y%m%d-%H%M%S)-$$}" | tr -c 'A-Za-z0-9_-' '_')"
run_token="${run_token:0:64}"
[[ -n "${run_token}" ]] || {
  echo "RUN_TOKEN is empty after sanitization" >&2
  exit 2
}
run_nonce="$(date +%s%N)-$$-${RANDOM}"
run_id="vnet-dynamic-${run_token}-${run_nonce}"
guest_run_dir="/tmp/${run_id}"
host_pin_root="/sys/fs/bpf/${run_id}"
guest_pin_root="/sys/fs/bpf/${run_id}"
host_client_pin="${host_pin_root}/dns-client"
host_grpc_pin="${host_pin_root}/grpc-monitor"
guest_server_pin="${guest_pin_root}/dns-server"
guest_client_grpc_pin="${guest_pin_root}/grpc-client"
guest_server_grpc_pin="${guest_pin_root}/grpc-server"
guest_backend_count="${guest_run_dir}/dns-backend-count"
guest_dns_harness="${guest_run_dir}/openstack_dns_harness"
guest_grpc_harness="${guest_run_dir}/openstack_grpc_harness"
guest_grpc_cache="${guest_run_dir}/grpc_fast_cache"
guest_cachectl="${guest_run_dir}/cachectl"
guest_dns_monitor="${guest_run_dir}/dns_monitor"
guest_dns_server_bpf="${guest_run_dir}/dns_xdp_monitor.bpf.o"
guest_controller="${guest_run_dir}/dynamic_cache_controller"
guest_stats_reader="${guest_run_dir}/dns_cache_stats_reader"
guest_server_cache="${guest_run_dir}/server-cache.txt"
guest_client_grpc_policy="${guest_run_dir}/grpc-client-policy.txt"
guest_server_grpc_policy="${guest_run_dir}/grpc-server-policy.txt"
guest_dns_backend_log="${guest_run_dir}/dns-backend.log"
guest_grpc_backend_log="${guest_run_dir}/grpc-backend.log"
guest_grpc_client_log="${guest_run_dir}/grpc-client.log"
guest_grpc_server_log="${guest_run_dir}/grpc-server.log"
guest_dns_monitor_log="${guest_run_dir}/dns-monitor.log"
guest_dns_backend_pid="${guest_run_dir}/dns-backend.pid"
guest_grpc_backend_pid="${guest_run_dir}/grpc-backend.pid"
guest_grpc_client_pid="${guest_run_dir}/grpc-client.pid"
guest_grpc_server_pid="${guest_run_dir}/grpc-server.pid"
guest_dns_monitor_pid="${guest_run_dir}/dns-monitor.pid"
sudo_askpass="${out_dir}/.sudo-askpass-${run_token}"
lock_key="$(printf '%s' "${client_tap}" | tr -c 'A-Za-z0-9_-' '_')"
campaign_lock_path="/tmp/vnet-dynamic-${lock_key}.lock"
campaign_lock_fd=""
grpc_security_group_rule_id=""

dns_client_pid=""
dns_client_start_time=""
grpc_monitor_pid=""
grpc_monitor_start_time=""
dynamic_in_fd=""
dynamic_out_fd=""
dynamic_pid=""
active_label=""

mkdir -p "${out_dir}/raw" "${out_dir}/monitors" "${out_dir}/decisions"
exec > >(tee "${out_dir}/run.log") 2>&1

if [[ -n "${sudo_password}" ]]; then
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$SUDO_PASS"' >"${sudo_askpass}"
  chmod 700 "${sudo_askpass}"
fi

sudo_cmd() {
  if [[ -n "${sudo_password}" ]]; then
    printf '%s\n' "${sudo_password}" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

sudo_stream_cmd() {
  if [[ -n "${sudo_password}" ]]; then
    SUDO_PASS="${sudo_password}" SUDO_ASKPASS="${sudo_askpass}" sudo -A "$@"
  else
    sudo "$@"
  fi
}

capture_openstack_evidence() {
  local status=0

  if [[ -n "${openstack_openrc}" ]]; then
    [[ -r "${openstack_openrc}" ]] || {
      echo "OPENSTACK_OPENRC is not readable: ${openstack_openrc}" >&2
      return 1
    }
    set +u
    # shellcheck source=/dev/null
    source "${openstack_openrc}" \
      "${openstack_openrc_user}" "${openstack_openrc_project}"
    set -u
  fi

  if ! command -v openstack >/dev/null 2>&1; then
    printf '%s\n' "openstack CLI not found" \
      >"${out_dir}/openstack-servers.txt"
    printf '%s\n' "openstack CLI not found" \
      >"${out_dir}/openstack-ports.txt"
    status=1
  else
    openstack server list --long \
      >"${out_dir}/openstack-servers.txt" 2>&1 || status=1
    openstack port list \
      >"${out_dir}/openstack-ports.txt" 2>&1 || status=1
  fi

  if (( status != 0 )); then
    echo "failed to capture authenticated OpenStack evidence" >&2
    [[ "${require_openstack_evidence}" == 0 ]] || return 1
  fi
}

ensure_grpc_security_group_rule() {
  local rule_id

  [[ "${manage_grpc_security_group_rule}" == 1 ]] || return 0
  [[ -n "${openstack_openrc}" ]] || {
    echo "MANAGE_GRPC_SECURITY_GROUP_RULE=1 requires OPENSTACK_OPENRC" >&2
    return 1
  }
  [[ -n "${openstack_grpc_backend_security_group_id}" ]] || {
    echo "MANAGE_GRPC_SECURITY_GROUP_RULE=1 requires OPENSTACK_GRPC_BACKEND_SECURITY_GROUP_ID" >&2
    return 1
  }
  command -v openstack >/dev/null 2>&1 || {
    echo "openstack CLI is required to manage the gRPC security-group rule" >&2
    return 1
  }

  rule_id="$(openstack security group rule create \
    --ingress --protocol tcp --dst-port 50052 \
    --remote-ip "${client_ip}/32" \
    "${openstack_grpc_backend_security_group_id}" -f value -c id)" || return 1
  grpc_security_group_rule_id="${rule_id}"
  [[ "${rule_id}" =~ ^[0-9a-fA-F-]+$ ]] || {
    echo "invalid managed gRPC security-group rule id: ${rule_id}" >&2
    return 1
  }
  {
    echo "managed_grpc_security_group_rule_id=${grpc_security_group_rule_id}"
    echo "managed_grpc_security_group_id=${openstack_grpc_backend_security_group_id}"
    echo "managed_grpc_security_group_source=${client_ip}/32"
    openstack security group rule show "${grpc_security_group_rule_id}" -f json
  } >"${out_dir}/grpc-security-group-rule.txt" || return 1
}

cleanup_grpc_security_group_rule() {
  local rule_id="${grpc_security_group_rule_id}"
  local delete_output delete_status show_output show_status

  [[ -n "${rule_id}" ]] || return 0
  if delete_output="$(openstack security group rule delete "${rule_id}" 2>&1)"; then
    printf 'managed_grpc_security_group_rule_delete=ok id=%s\n' "${rule_id}" \
      >>"${out_dir}/grpc-security-group-rule.txt"
  else
    delete_status=$?
    {
      printf 'managed_grpc_security_group_rule_delete=failed id=%s status=%s\n' \
        "${rule_id}" "${delete_status}"
      printf '%s\n' "${delete_output}"
    } >>"${out_dir}/grpc-security-group-rule.txt"
    return 1
  fi
  if show_output="$(openstack security group rule show "${rule_id}" 2>&1)"; then
    echo "managed gRPC security-group rule still exists: ${rule_id}" >&2
    {
      printf 'managed_grpc_security_group_rule_verify=present id=%s status=0\n' \
        "${rule_id}"
      printf '%s\n' "${show_output}"
    } >>"${out_dir}/grpc-security-group-rule.txt"
    return 1
  else
    show_status=$?
  fi
  if ! grep -Eqi '(^|[^0-9])404([^0-9]|$)|[Nn]ot[[:space:]-]*[Ff]ound|[Nn]o[[:space:]].*[[:space:]][Ff]ound' \
      <<<"${show_output}"; then
    echo "unable to verify managed gRPC security-group rule deletion: ${rule_id}" >&2
    {
      printf 'managed_grpc_security_group_rule_verify=error id=%s status=%s\n' \
        "${rule_id}" "${show_status}"
      printf '%s\n' "${show_output}"
    } >>"${out_dir}/grpc-security-group-rule.txt"
    return 1
  fi
  printf 'managed_grpc_security_group_rule_verify=not_found id=%s status=%s\n' \
    "${rule_id}" "${show_status}" >>"${out_dir}/grpc-security-group-rule.txt"
  printf 'managed_grpc_security_group_rule_deleted=%s\n' "${rule_id}" \
    >>"${out_dir}/grpc-security-group-rule.txt"
  grpc_security_group_rule_id=""
}

ssh_opts=(
  -i "${guest_key}"
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

guest_cmd() {
  local ip="$1"
  local command="$2"
  local encoded status
  encoded="$(printf '%s' "${command}" | base64 | tr -d '\n')"
  if sudo_cmd ip netns exec "${netns}" ssh "${ssh_opts[@]}" \
      "${guest_user}@${ip}" "echo ${encoded} | base64 -d | bash"; then
    return 0
  else
    status=$?
  fi
  printf 'guest_command_failed ip=%s status=%s\n' "${ip}" "${status}" >&2
  return "${status}"
}

copy_guest() {
  local ip="$1"
  local source_file="$2"
  local target_file="$3"
  gzip -1c "${source_file}" | base64 | tr -d '\n' |
    sudo_stream_cmd ip netns exec "${netns}" ssh "${ssh_opts[@]}" \
      "${guest_user}@${ip}" \
      "base64 -d | gzip -d > '${target_file}' && chmod +x '${target_file}'"
}

guest_process_helpers() {
  cat <<'EOF'
record_owned_process() {
  local state_file="$1"
  local pid="$2"
  local pgid start_time

  pgid="$(sudo -n ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  start_time="$(sudo -n awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$pgid" in ''|*[!0-9]*) return 1 ;; esac
  case "$start_time" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$pid" != "$pgid" ]; then
    echo "refusing to track non-private process group for pid $pid" >&2
    return 1
  fi
  printf '%s %s %s\n' "$pid" "$pgid" "$start_time" >"$state_file"
}

stop_owned_process() {
  local state_file="$1"
  local pid pgid start_time actual_pgid actual_start

  [ -s "$state_file" ] || return 0
  read -r pid pgid start_time <"$state_file" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$pgid" in ''|*[!0-9]*) return 1 ;; esac
  case "$start_time" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" = "$pgid" ] || return 1

  actual_pgid="$(sudo -n ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  actual_start="$(sudo -n awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
  if [ "$actual_pgid" != "$pgid" ] || [ "$actual_start" != "$start_time" ]; then
    echo "owned process identity changed for pid $pid; not signaling it" >&2
    return 1
  fi

  sudo -n kill -TERM -- "-$pgid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    sudo -n kill -0 -- "-$pgid" 2>/dev/null || break
    sleep 0.05
  done
  if sudo -n kill -0 -- "-$pgid" 2>/dev/null; then
    sudo -n kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  if sudo -n kill -0 -- "-$pgid" 2>/dev/null; then
    echo "owned process group $pgid did not stop" >&2
    return 1
  fi
  rm -f -- "$state_file"
}
EOF
}

guest_start_tracked_process() {
  local ip="$1"
  local state_file="$2"
  local log_file="$3"
  local command="$4"
  local encoded

  encoded="$(printf '%s' "${command}" | base64 | tr -d '\n')"
  guest_cmd "${ip}" "$(guest_process_helpers)
setsid nohup bash -c 'echo ${encoded} | base64 -d | bash' >'${log_file}' 2>&1 </dev/null &
pid=\$!
record_owned_process '${state_file}' \"\$pid\""
}

guest_run_tracked_process() {
  local ip="$1"
  local state_file="$2"
  local command="$3"
  local encoded runner runner_encoded gate_file

  encoded="$(printf '%s' "${command}" | base64 | tr -d '\n')"
  gate_file="${state_file}.ready"
  runner="while [ ! -e '${gate_file}' ]; do sleep 0.01; done
rm -f -- '${gate_file}'
echo ${encoded} | base64 -d | bash
command_status=\$?
if [ \"\$command_status\" -ne 0 ]; then
  printf 'guest_workload_command_status=%s state=%s\n' \"\$command_status\" '${state_file}' >&2
fi
exit \"\$command_status\""
  runner_encoded="$(printf '%s' "${runner}" | base64 | tr -d '\n')"
  guest_cmd "${ip}" "$(guest_process_helpers)
rm -f -- '${state_file}' '${gate_file}'
setsid bash -c 'echo ${runner_encoded} | base64 -d | bash' </dev/null &
pid=\$!
if ! record_owned_process '${state_file}' \"\$pid\"; then
  printf 'failed_to_record_guest_workload state=%s pid=%s\n' '${state_file}' \"\$pid\" >&2
  kill -TERM \"\$pid\" 2>/dev/null || true
  wait \"\$pid\" >/dev/null 2>&1 || true
  rm -f -- '${state_file}' '${gate_file}'
  exit 1
fi
: > '${gate_file}' || {
  printf 'failed_to_release_guest_workload state=%s pid=%s\n' '${state_file}' \"\$pid\" >&2
  stop_owned_process '${state_file}' || true
  rm -f -- '${state_file}' '${gate_file}'
  exit 1
}
wait \"\$pid\"
status=\$?
if [ \"\$status\" -ne 0 ]; then
  printf 'guest_workload_wait_status=%s state=%s\n' \"\$status\" '${state_file}' >&2
fi
rm -f -- '${state_file}' '${gate_file}'
exit \"\$status\""
}

stop_guest_owned_processes() {
  local ip="$1"
  shift
  local state_file
  local command

  command="$(guest_process_helpers)"
  for state_file in "$@"; do
    [[ "${state_file}" == "${guest_run_dir}/"* ]] || {
      echo "unsafe owned process state: ${state_file}" >&2
      return 1
    }
    command+=$'\n'
    command+="stop_owned_process '${state_file}'"
  done
  guest_cmd "${ip}" "${command}"
}

stop_all_guest_owned_processes() {
  local ip="$1"

  guest_cmd "${ip}" "$(guest_process_helpers)
status=0
for state_file in '${guest_run_dir}'/*.pid; do
  [ -e \"\$state_file\" ] || continue
  stop_owned_process \"\$state_file\" || status=1
done
exit \"\$status\""
}

field() {
  tr ' ' '\n' <<<"$1" | awk -F= -v wanted="$2" \
    '$1 == wanted {print $2; exit}'
}

delta_field() {
  local after="$1"
  local before="$2"
  local name="$3"
  local after_value before_value
  after_value="$(field "${after}" "${name}")"
  before_value="$(field "${before}" "${name}")"
  printf '%s\n' "$((after_value - before_value))"
}

host_process_start_time() {
  local pid="$1"
  local start_time pgid sid

  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  start_time="$(sudo_cmd awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null)"
  pgid="$(sudo_cmd ps -o pgid= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
  sid="$(sudo_cmd ps -o sid= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${start_time}" =~ ^[0-9]+$ && "${pgid}" == "${pid}" &&
     "${sid}" == "${pid}" ]] || return 1
  printf '%s\n' "${start_time}"
}

stop_host_process() {
  local pid="$1"
  local expected_start_time="$2"
  local current_start_time

  [[ -n "${pid}" ]] || return 0
  [[ "${pid}" =~ ^[0-9]+$ && "${expected_start_time}" =~ ^[0-9]+$ ]] || {
    echo "invalid host monitor identity: pid=${pid} start=${expected_start_time}" >&2
    return 1
  }
  if ! sudo_cmd kill -0 "${pid}" >/dev/null 2>&1; then
    if sudo_cmd kill -0 -- "-${pid}" >/dev/null 2>&1; then
      echo "host monitor leader ${pid} exited while its process group remains" >&2
      return 1
    fi
    return 0
  fi
  current_start_time="$(host_process_start_time "${pid}")" || {
    echo "refusing to signal host monitor without its private process group: ${pid}" >&2
    return 1
  }
  [[ "${current_start_time}" == "${expected_start_time}" ]] || {
    echo "refusing to signal reused host monitor pid: ${pid}" >&2
    return 1
  }
  sudo_cmd kill -TERM -- "-${pid}" >/dev/null 2>&1 || true
  for _ in {1..50}; do
    sudo_cmd kill -0 -- "-${pid}" >/dev/null 2>&1 || return 0
    sleep 0.05
  done
  sudo_cmd kill -KILL -- "-${pid}" >/dev/null 2>&1 || true
  sudo_cmd kill -0 -- "-${pid}" >/dev/null 2>&1 && {
    echo "host monitor process group ${pid} did not stop" >&2
    return 1
  }
}

stop_monitors() {
  local status=0

  if [[ -n "${grpc_monitor_pid}" ]]; then
    if stop_host_process "${grpc_monitor_pid}" "${grpc_monitor_start_time}"; then
      grpc_monitor_pid=""
      grpc_monitor_start_time=""
    else
      status=1
    fi
  fi
  if [[ -n "${dns_client_pid}" ]]; then
    if stop_host_process "${dns_client_pid}" "${dns_client_start_time}"; then
      dns_client_pid=""
      dns_client_start_time=""
    else
      status=1
    fi
  fi
  stop_guest_owned_processes "${client_ip}" \
    "${guest_grpc_client_pid}" || status=1
  stop_guest_owned_processes "${backend_ip}" \
    "${guest_grpc_server_pid}" "${guest_dns_monitor_pid}" || status=1
  if [[ -n "${active_label}" ]]; then
    guest_cmd "${client_ip}" \
      "cat '${guest_grpc_client_log}' 2>/dev/null || true" \
      >"${out_dir}/monitors/${active_label}.grpc-client-cache.log" 2>&1 || true
    guest_cmd "${backend_ip}" \
      "cat '${guest_grpc_server_log}' 2>/dev/null || true" \
      >"${out_dir}/monitors/${active_label}.grpc-server-cache.log" 2>&1 || true
    guest_cmd "${backend_ip}" \
      "cat '${guest_dns_monitor_log}' 2>/dev/null || true" \
      >"${out_dir}/monitors/${active_label}.dns-server.log" 2>&1 || true
  fi
  active_label=""
  return "${status}"
}

stop_dynamic_controller() {
  if [[ -n "${dynamic_in_fd}" ]]; then
    exec {dynamic_in_fd}>&-
    dynamic_in_fd=""
  fi
  if [[ -n "${dynamic_pid}" ]]; then
    wait "${dynamic_pid}" >/dev/null 2>&1 || true
    dynamic_pid=""
  fi
  if [[ -n "${dynamic_out_fd}" ]]; then
    exec {dynamic_out_fd}<&-
  fi
  dynamic_out_fd=""
}

cleanup() {
  local status=$?
  local cleanup_failed=0
  local host_pin_residue host_process_residue host_tc_residue
  local host_tc_state
  local client_residue backend_residue
  trap - EXIT
  set +e
  stop_dynamic_controller
  stop_monitors || cleanup_failed=1
  stop_all_guest_owned_processes "${client_ip}" || cleanup_failed=1
  stop_all_guest_owned_processes "${backend_ip}" || cleanup_failed=1
  cleanup_grpc_security_group_rule || cleanup_failed=1
  guest_cmd "${backend_ip}" \
    'echo "--- dns backend ---"
     cat '"${guest_dns_backend_log}"' 2>/dev/null || true
     echo "--- grpc backend ---"
     cat '"${guest_grpc_backend_log}"' 2>/dev/null || true' \
    >"${out_dir}/monitors/backend-startup.log" 2>&1 || true
  if (( cleanup_failed == 0 )); then
    sudo_cmd rm -rf -- "${host_pin_root}" || cleanup_failed=1
    guest_cmd "${client_ip}" \
      "sudo -n rm -rf -- '${guest_pin_root}' '${guest_run_dir}'" || cleanup_failed=1
    guest_cmd "${backend_ip}" \
      "sudo -n rm -rf -- '${guest_pin_root}' '${guest_run_dir}'" || cleanup_failed=1
  else
    echo "preserving run directories and pin roots after lifecycle validation failure" >&2
  fi

  if (( cleanup_failed != 0 )); then
    [[ "${status}" -ne 0 ]] || status=1
  fi

  if ! host_pin_residue="$(sudo_cmd find /sys/fs/bpf -maxdepth 1 -type d \
       -name "${run_id}" \
       -print 2>/dev/null)"; then
    host_pin_residue="host_pin_audit_failed"
  fi
  host_process_residue="$(ps -eo pid=,args= |
    grep -F "${run_id}" |
    grep -v grep || true)"
  if host_tc_state="$(
       sudo_cmd tc filter show dev "${client_tap}" ingress &&
       sudo_cmd tc filter show dev "${client_tap}" egress
     )"; then
    host_tc_residue="$(grep -E 'handle 0x(1|2) ' <<<"${host_tc_state}" || true)"
  else
    host_tc_state="host_tc_audit_failed"
    host_tc_residue="${host_tc_state}"
  fi
  if ! client_residue="$(guest_cmd "${client_ip}" \
       "ps -eo pid=,args= | grep -F '${guest_run_dir}' | grep -v grep || true
        sudo -n find /sys/fs/bpf -maxdepth 1 -type d -name '${run_id}' -print
        sudo -n test ! -e '${guest_run_dir}' || echo '${guest_run_dir}'")"; then
    client_residue="client_guest_audit_failed"
  fi
  if ! backend_residue="$(guest_cmd "${backend_ip}" \
       "ps -eo pid=,args= | grep -F '${guest_run_dir}' | grep -v grep || true
        sudo -n find /sys/fs/bpf -maxdepth 1 -type d -name '${run_id}' -print
        sudo -n test ! -e '${guest_run_dir}' || echo '${guest_run_dir}'")"; then
    backend_residue="backend_guest_audit_failed"
  fi

  if [[ -n "${host_pin_residue}${host_process_residue}${host_tc_residue}${client_residue}${backend_residue}" ]]; then
    cleanup_failed=1
    [[ "${status}" -ne 0 ]] || status=1
  fi
  {
    echo "host_runtime_pins=${host_pin_residue:-none}"
    echo "host_test_processes=${host_process_residue:-none}"
    echo "host_owned_tc_filters=${host_tc_residue:-none}"
    echo "host_tc_state:"
    printf '%s\n' "${host_tc_state}"
    echo "client_guest_residue=${client_residue:-none}"
    echo "backend_guest_residue=${backend_residue:-none}"
    echo "cleanup_residue=${cleanup_failed}"
  } >"${out_dir}/cleanup-audit.txt" 2>&1
  rm -f "${sudo_askpass}"
  printf 'cleanup_status=%s\ncleanup_residue=%s\n' \
    "${status}" "${cleanup_failed}" >"${out_dir}/cleanup-status.txt"
  exit "${status}"
}
trap cleanup EXIT

for file in \
  "${dns_harness}" "${grpc_harness}" "${grpc_cache}" "${cachectl}" \
  "${dns_monitor}" "${dns_client_bpf}" "${dns_server_bpf}" \
  "${grpc_monitor}" "${grpc_bpf}" "${controller}" "${stats_reader}"; do
  [[ -x "${file}" || -r "${file}" ]] || {
    echo "missing campaign input: ${file}" >&2
    exit 1
  }
done

for value_name in rounds windows requests_per_window burst_clients; do
  value="${!value_name}"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
    echo "${value_name} must be a positive integer" >&2
    exit 2
  }
done
[[ "${warmup}" =~ ^[0-9]+$ ]] || {
  echo "warmup must be a non-negative integer" >&2
  exit 2
}
[[ "${require_netmig_tc}" == 0 || "${require_netmig_tc}" == 1 ]] || {
  echo "REQUIRE_NETMIG_TC must be 0 or 1" >&2
  exit 2
}
[[ "${require_openstack_evidence}" == 0 ||
   "${require_openstack_evidence}" == 1 ]] || {
  echo "REQUIRE_OPENSTACK_EVIDENCE must be 0 or 1" >&2
  exit 2
}
[[ "${manage_grpc_security_group_rule}" == 0 ||
   "${manage_grpc_security_group_rule}" == 1 ]] || {
  echo "MANAGE_GRPC_SECURITY_GROUP_RULE must be 0 or 1" >&2
  exit 2
}
if [[ "${manage_grpc_security_group_rule}" == 1 ]]; then
  [[ -n "${openstack_openrc}" &&
     -n "${openstack_grpc_backend_security_group_id}" ]] || {
    echo "managed gRPC security-group rule requires OPENSTACK_OPENRC and OPENSTACK_GRPC_BACKEND_SECURITY_GROUP_ID" >&2
    exit 2
  }
fi
if (( requests_per_window < burst_clients || requests_per_window < 8 )); then
  echo "REQUESTS_PER_WINDOW must be at least BURST_CLIENTS and 8" >&2
  exit 2
fi
if (( requests_per_window % burst_clients != 0 ||
      requests_per_window % 8 != 0 )); then
  echo "REQUESTS_PER_WINDOW must be divisible by BURST_CLIENTS and 8" >&2
  exit 2
fi

read -r -a policies <<<"${policy_set}"
read -r -a workloads <<<"${workload_set}"
(( ${#policies[@]} > 0 && ${#workloads[@]} > 0 )) || {
  echo "POLICIES and WORKLOADS must not be empty" >&2
  exit 2
}
has_dynamic=0
for policy in "${policies[@]}"; do
  case "${policy}" in
    bypass|server|client|dual) ;;
    dynamic) has_dynamic=1 ;;
    *)
      echo "unknown policy: ${policy}" >&2
      exit 2
      ;;
  esac
done
for workload in "${workloads[@]}"; do
  case "${workload}" in
    stable|burst|hot-key|shifting-hot-key|low-hit-rate) ;;
    *)
      echo "unknown workload: ${workload}" >&2
      exit 2
      ;;
  esac
done
if (( has_dynamic && windows < 3 )); then
  echo "dynamic policy requires at least three windows" >&2
  exit 2
fi

command -v flock >/dev/null 2>&1 || {
  echo "flock is required to serialize campaigns on ${client_tap}" >&2
  exit 2
}
exec {campaign_lock_fd}>"${campaign_lock_path}"
flock -n "${campaign_lock_fd}" || {
  echo "another dynamic campaign already owns ${client_tap}" >&2
  exit 2
}

{
  echo "timestamp=$(date --iso-8601=seconds)"
  echo "kernel=$(uname -r)"
  echo "client_ip=${client_ip}"
  echo "backend_ip=${backend_ip}"
  echo "client_tap=${client_tap}"
  echo "netns=${netns}"
  echo "rounds=${rounds}"
  echo "windows=${windows}"
  echo "requests_per_window=${requests_per_window}"
  echo "policies=${policies[*]}"
  echo "workloads=${workloads[*]}"
  echo "run_token=${run_token}"
  echo "run_id=${run_id}"
  echo "campaign_lock=${campaign_lock_path}"
  echo "require_netmig_tc=${require_netmig_tc}"
  echo "require_openstack_evidence=${require_openstack_evidence}"
  echo "manage_grpc_security_group_rule=${manage_grpc_security_group_rule}"
  echo "openstack_grpc_backend_security_group_id=${openstack_grpc_backend_security_group_id:-none}"
  echo "source_revision=${source_revision}"
} >"${out_dir}/environment.txt"
capture_openstack_evidence
ensure_grpc_security_group_rule
sudo_cmd ovs-vsctl show >"${out_dir}/ovs-topology.txt" 2>&1 || true
sudo_cmd ip -details link show "${client_tap}" \
  >"${out_dir}/client-interface.txt" 2>&1

guest_cmd "${client_ip}" "umask 077; mkdir -p -- '${guest_run_dir}'"
guest_cmd "${backend_ip}" "umask 077; mkdir -p -- '${guest_run_dir}'"
copy_guest "${client_ip}" "${dns_harness}" "${guest_dns_harness}"
copy_guest "${client_ip}" "${grpc_harness}" "${guest_grpc_harness}"
copy_guest "${client_ip}" "${grpc_cache}" "${guest_grpc_cache}"
copy_guest "${client_ip}" "${cachectl}" "${guest_cachectl}"
copy_guest "${client_ip}" "${controller}" "${guest_controller}"
copy_guest "${backend_ip}" "${dns_harness}" "${guest_dns_harness}"
copy_guest "${backend_ip}" "${grpc_harness}" "${guest_grpc_harness}"
copy_guest "${backend_ip}" "${grpc_cache}" "${guest_grpc_cache}"
copy_guest "${backend_ip}" "${cachectl}" "${guest_cachectl}"
copy_guest "${backend_ip}" "${dns_monitor}" "${guest_dns_monitor}"
copy_guest "${backend_ip}" "${dns_server_bpf}" "${guest_dns_server_bpf}"
copy_guest "${backend_ip}" "${controller}" "${guest_controller}"
copy_guest "${backend_ip}" "${stats_reader}" "${guest_stats_reader}"

server_cache_file="${out_dir}/server-cache.txt"
printf 'hot.%s %s 600\n' "${domain}" "${answer_ip}" >"${server_cache_file}"
printf 'shift-a.%s %s 600\n' "${domain}" "${answer_ip}" >>"${server_cache_file}"
printf 'shift-b.%s %s 600\n' "${domain}" "${answer_ip}" >>"${server_cache_file}"
for key in $(seq 0 7); do
  printf 'key-%s.%s %s 600\n' "${key}" "${domain}" "${answer_ip}" \
    >>"${server_cache_file}"
done
copy_guest "${backend_ip}" "${server_cache_file}" "${guest_server_cache}"

guest_cmd "${backend_ip}" \
  "set -e
   sudo -n mkdir -p /sys/fs/bpf
   mountpoint -q /sys/fs/bpf || sudo -n mount -t bpf bpf /sys/fs/bpf
   sudo -n install -d -m 0755 '${guest_pin_root}'
   sudo -n rm -rf -- '${guest_server_pin}' '${guest_server_grpc_pin}'
   printf '0\n' | sudo -n tee '${guest_backend_count}' >/dev/null"
guest_start_tracked_process "${backend_ip}" "${guest_dns_backend_pid}" \
  "${guest_dns_backend_log}" \
  "sudo -n '${guest_dns_harness}' server '${backend_ip}' 53 '${domain}' '${answer_ip}' 600 '${guest_backend_count}'"
guest_start_tracked_process "${backend_ip}" "${guest_grpc_backend_pid}" \
  "${guest_grpc_backend_log}" \
  "sudo -n '${guest_grpc_harness}' server '${backend_ip}' 50051 300"
guest_cmd "${client_ip}" \
  "sudo -n mkdir -p /sys/fs/bpf
   mountpoint -q /sys/fs/bpf || sudo -n mount -t bpf bpf /sys/fs/bpf
   sudo -n install -d -m 0755 '${guest_pin_root}'
   sudo -n rm -rf -- '${guest_client_grpc_pin}'"
sleep 1

guest_cmd "${backend_ip}" \
  "set -e
   ps -eo pid=,args= | grep -F '${guest_run_dir}' | grep -v grep
   ss -lunp | grep '${backend_ip}:53 '
   ss -ltnp | grep ':50051 '" >"${out_dir}/service-state.txt"

verify_tc_order() {
  local label="$1"
  local ingress="${out_dir}/monitors/${label}.tc-ingress.txt"
  local egress="${out_dir}/monitors/${label}.tc-egress.txt"
  sudo_cmd tc filter show dev "${client_tap}" ingress >"${ingress}"
  sudo_cmd tc filter show dev "${client_tap}" egress >"${egress}"
  if [[ "${require_netmig_tc}" == 1 ]]; then
    awk '
      /handle 0x1 / {dns=NR}
      /handle 0x2 / {grpc=NR}
      /handle 0x65 / {netmig=NR}
      END {exit !(dns && grpc && netmig && dns < netmig && grpc < netmig)}
    ' "${ingress}"
    awk '
      /handle 0x1 / {dns=NR}
      /handle 0x2 / {grpc=NR}
      /handle 0x66 / {netmig=NR}
      END {exit !(dns && grpc && netmig && dns < netmig && grpc < netmig)}
    ' "${egress}"
  else
    awk '
      /handle 0x1 / {dns=1}
      /handle 0x2 / {grpc=1}
      END {exit !(dns && grpc)}
    ' "${ingress}"
    awk '
      /handle 0x1 / {dns=1}
      /handle 0x2 / {grpc=1}
      END {exit !(dns && grpc)}
    ' "${egress}"
  fi
}

start_monitors() {
  local label="$1"
  stop_monitors || {
    echo "previous monitor lifecycle could not be verified" >&2
    return 1
  }
  active_label="${label}"
  sudo_cmd rm -rf -- "${host_pin_root}"
  sudo_cmd mkdir -p -- "${host_pin_root}"
  guest_cmd "${client_ip}" \
    "sudo -n rm -rf -- '${guest_client_grpc_pin}'
     sudo -n mkdir -p '${guest_client_grpc_pin}'
     sudo -n '${guest_grpc_harness}' seed '${guest_client_grpc_pin}/grpc_policy_map'
     sudo -n '${guest_grpc_harness}' seed-response '${guest_client_grpc_pin}/grpc_response_cache' '${grpc_payload}' SERVING 3600
     printf '%s\n' 'grpc ${method} 3600 idempotent' 'grpc-cache ${method} ${grpc_payload} SERVING 3600' 'grpc-cache ${method} ${grpc_shift_payload} SERVING 3600' >'${guest_client_grpc_policy}'
     for i in \$(seq 0 7); do printf 'grpc-cache ${method} key-%s SERVING 3600\n' \"\$i\" >>'${guest_client_grpc_policy}'; done
     sudo -n '${guest_cachectl}' --policy-file '${guest_client_grpc_policy}' --grpc-map '${guest_client_grpc_pin}/grpc_policy_map' --grpc-response-map '${guest_client_grpc_pin}/grpc_response_cache' --replace
     sudo -n bpftool map create '${guest_client_grpc_pin}/cache_runtime_control' type array key 4 value 16 entries 1 name dyn_grpc_cli"
  guest_start_tracked_process "${client_ip}" "${guest_grpc_client_pid}" \
    "${guest_grpc_client_log}" \
    "sudo -n '${guest_grpc_cache}' --grpc-map '${guest_client_grpc_pin}/grpc_policy_map' --grpc-response-map '${guest_client_grpc_pin}/grpc_response_cache' --runtime-control-map '${guest_client_grpc_pin}/cache_runtime_control' --cache-role client --listen '${client_ip}':50053 --backend '${backend_ip}':50052 --method '${method}' --verbose"
  guest_cmd "${backend_ip}" \
    "sudo -n rm -rf -- '${guest_server_pin}' '${guest_server_grpc_pin}'
     sudo -n mkdir -p '${guest_server_grpc_pin}'
     sudo -n '${guest_grpc_harness}' seed '${guest_server_grpc_pin}/grpc_policy_map'
     sudo -n '${guest_grpc_harness}' seed-response '${guest_server_grpc_pin}/grpc_response_cache' '${grpc_payload}' SERVING 3600
     printf '%s\n' 'grpc ${method} 3600 idempotent' 'grpc-cache ${method} ${grpc_payload} SERVING 3600' 'grpc-cache ${method} ${grpc_shift_payload} SERVING 3600' >'${guest_server_grpc_policy}'
     for i in \$(seq 0 7); do printf 'grpc-cache ${method} key-%s SERVING 3600\n' \"\$i\" >>'${guest_server_grpc_policy}'; done
     sudo -n '${guest_cachectl}' --policy-file '${guest_server_grpc_policy}' --grpc-map '${guest_server_grpc_pin}/grpc_policy_map' --grpc-response-map '${guest_server_grpc_pin}/grpc_response_cache' --replace
     sudo -n bpftool map create '${guest_server_grpc_pin}/cache_runtime_control' type array key 4 value 16 entries 1 name dyn_grpc_srv"
  guest_start_tracked_process "${backend_ip}" "${guest_grpc_server_pid}" \
    "${guest_grpc_server_log}" \
    "sudo -n '${guest_grpc_cache}' --grpc-map '${guest_server_grpc_pin}/grpc_policy_map' --grpc-response-map '${guest_server_grpc_pin}/grpc_response_cache' --runtime-control-map '${guest_server_grpc_pin}/cache_runtime_control' --cache-role server --listen '${backend_ip}':50052 --backend '${backend_ip}':50051 --method '${method}' --verbose"
  guest_start_tracked_process "${backend_ip}" "${guest_dns_monitor_pid}" \
    "${guest_dns_monitor_log}" \
    "sudo -n '${guest_dns_monitor}' --dev ens3 --hook xdp --role server --xdp-mode generic --bpf-object '${guest_dns_server_bpf}' --cache-file '${guest_server_cache}' --pin-dir '${guest_server_pin}'"
  dns_client_pid="$(sudo_cmd bash -c \
    "setsid '${dns_monitor}' --dev '${client_tap}' --hook xdp --role client --xdp-mode generic --bpf-object '${dns_client_bpf}' --trusted-dns '${backend_ip}' --pin-dir '${host_client_pin}' >'${out_dir}/monitors/${label}.dns-client.log' 2>&1 </dev/null & echo \$!")"
  dns_client_start_time="$(host_process_start_time "${dns_client_pid}")" || {
    echo "failed to record DNS host monitor identity" >&2
    return 1
  }
  grpc_monitor_pid="$(sudo_cmd bash -c \
    "setsid '${grpc_monitor}' --dev '${client_tap}' --bpf-object '${grpc_bpf}' --port 50052 --pin-dir '${host_grpc_pin}' >'${out_dir}/monitors/${label}.grpc.log' 2>&1 </dev/null & echo \$!")"
  grpc_monitor_start_time="$(host_process_start_time "${grpc_monitor_pid}")" || {
    echo "failed to record gRPC host monitor identity" >&2
    return 1
  }
  for _ in {1..80}; do
    if sudo_cmd test -e "${host_client_pin}/cache_runtime_control" &&
       guest_cmd "${client_ip}" \
         "sudo -n test -e ${guest_client_grpc_pin}/cache_runtime_control && ss -ltn | grep -q ':50053 '" &&
       guest_cmd "${backend_ip}" \
         "sudo -n test -e ${guest_server_pin}/cache_runtime_control && sudo -n test -e ${guest_server_grpc_pin}/cache_runtime_control && ss -ltn | grep -q ':50052 '"; then
      sudo_cmd ip -details link show dev "${client_tap}" |
        grep -q 'prog/xdp'
      guest_cmd "${backend_ip}" \
        "sudo -n ip -details link show dev ens3 | grep -q 'prog/xdp'"
      verify_tc_order "${label}"
      return 0
    fi
    sleep 0.1
  done
  echo "runtime maps did not appear for ${label}" >&2
  exit 1
}

apply_mode() {
  local mode="$1"
  local epoch="$2"
  local label="$3"
  local previous_mode="${4:-}"
  local previous_epoch="${5:-}"
  if sudo_stream_cmd "${controller}" \
       --control-map "${host_client_pin}/cache_runtime_control" \
       --initial-mode "${mode}" --initial-epoch "${epoch}" </dev/null \
       >"${out_dir}/decisions/${label}.host-publish.log" 2>&1 &&
     guest_cmd "${client_ip}" \
       "sudo -n '${guest_controller}' --control-map '${guest_client_grpc_pin}/cache_runtime_control' --initial-mode '${mode}' --initial-epoch '${epoch}' </dev/null" \
       >"${out_dir}/decisions/${label}.client-publish.log" 2>&1 &&
     guest_cmd "${backend_ip}" \
       "sudo -n '${guest_controller}' --control-map '${guest_server_pin}/cache_runtime_control' --control-map '${guest_server_grpc_pin}/cache_runtime_control' --initial-mode '${mode}' --initial-epoch '${epoch}' </dev/null" \
       >"${out_dir}/decisions/${label}.server-publish.log" 2>&1; then
    return 0
  fi

  echo "cache mode publication failed for ${label}" >&2
  if [[ -n "${previous_mode}" && -n "${previous_epoch}" ]]; then
    sudo_stream_cmd "${controller}" \
      --control-map "${host_client_pin}/cache_runtime_control" \
      --initial-mode "${previous_mode}" --initial-epoch "${previous_epoch}" \
      </dev/null >"${out_dir}/decisions/${label}.host-rollback.log" 2>&1 || true
    guest_cmd "${client_ip}" \
      "sudo -n '${guest_controller}' --control-map '${guest_client_grpc_pin}/cache_runtime_control' --initial-mode '${previous_mode}' --initial-epoch '${previous_epoch}' </dev/null" \
      >"${out_dir}/decisions/${label}.client-rollback.log" 2>&1 || true
    guest_cmd "${backend_ip}" \
      "sudo -n '${guest_controller}' --control-map '${guest_server_pin}/cache_runtime_control' --control-map '${guest_server_grpc_pin}/cache_runtime_control' --initial-mode '${previous_mode}' --initial-epoch '${previous_epoch}' </dev/null" \
      >"${out_dir}/decisions/${label}.server-rollback.log" 2>&1 || true
  fi
  return 1
}

host_dns_stats() {
  sudo_cmd "${stats_reader}" "${host_client_pin}/dns_cache_stats"
}

guest_dns_stats() {
  guest_cmd "${backend_ip}" \
    "sudo -n '${guest_stats_reader}' '${guest_server_pin}/dns_cache_stats'"
}

client_grpc_stats() {
  guest_cmd "${client_ip}" \
    "grep 'grpc_fast_cache listen=' '${guest_grpc_client_log}' | tail -n 1"
}

server_grpc_stats() {
  guest_cmd "${backend_ip}" \
    "grep 'grpc_fast_cache listen=' '${guest_grpc_server_log}' | tail -n 1"
}

backend_count() {
  guest_cmd "${backend_ip}" \
    "tail -n 1 '${guest_backend_count}' | tr -d '[:space:]'"
}

aggregate_output() {
  local file="$1"
  local success_name="$2"
  awk -v success_name="${success_name}" '
    {
      success=failed=p95=0
      for (i=1; i<=NF; i++) {
        split($i, pair, "=")
        if (pair[1] == success_name) success=pair[2]
        else if (pair[1] == "failed") failed=pair[2]
        else if (pair[1] == "p95_us") p95=pair[2]
      }
      total_success += success
      total_failed += failed
      if (p95 > max_p95) max_p95 = p95
    }
    END {
      printf "success=%d failed=%d p95_us=%.2f\n",
             total_success, total_failed, max_p95
    }
  ' "${file}"
}

run_dns_load() {
  local workload="$1"
  local output="$2"
  local window="$3"
  local shifting_domain
  local state_file="${guest_run_dir}/dns-load-${active_label}-w${window}.pid"
  case "${workload}" in
    stable)
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "'${guest_dns_harness}' client-workload '${backend_ip}' 53 '${domain}' '${answer_ip}' '${requests_per_window}' '${warmup}' stable 8" >"${output}"
      ;;
    burst)
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "rm -f -- ${guest_run_dir}/dns-burst-*.out
         pids=()
         for i in \$(seq 1 '${burst_clients}'); do
            '${guest_dns_harness}' client-workload '${backend_ip}' 53 '${domain}' '${answer_ip}' '$((requests_per_window / burst_clients))' '$((warmup / burst_clients))' hot 1 >${guest_run_dir}/dns-burst-\$i.out &
            pids+=(\"\$!\")
         done
         status=0
         for pid in \"\${pids[@]}\"; do
           wait \"\$pid\" || status=1
         done
         cat ${guest_run_dir}/dns-burst-*.out || status=1
         exit \"\$status\"" >"${output}"
      ;;
    hot-key)
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "'${guest_dns_harness}' client-workload '${backend_ip}' 53 '${domain}' '${answer_ip}' '${requests_per_window}' '${warmup}' hot 1" >"${output}"
      ;;
    shifting-hot-key)
      if (( window <= windows / 2 )); then
        shifting_domain="shift-a.${domain}"
      else
        shifting_domain="shift-b.${domain}"
      fi
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "'${guest_dns_harness}' client-workload '${backend_ip}' 53 '${shifting_domain}' '${answer_ip}' '${requests_per_window}' '${warmup}' fixed 1" >"${output}"
      ;;
    low-hit-rate)
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "'${guest_dns_harness}' client-workload '${backend_ip}' 53 'w${window}.${domain}' '${answer_ip}' '${requests_per_window}' '${warmup}' low-hit-rate '${requests_per_window}'" >"${output}"
      ;;
    *)
      echo "unknown workload: ${workload}" >&2
      return 1
      ;;
  esac
}

run_grpc_load() {
  local workload="$1"
  local output="$2"
  local window="$3"
  local shifting_payload
  local state_file="${guest_run_dir}/grpc-load-${active_label}-w${window}.pid"
  case "${workload}" in
    stable)
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "rm -f -- ${guest_run_dir}/grpc-stable-*.out
         status=0
         for i in \$(seq 0 7); do
            '${guest_grpc_harness}' client '${client_ip}' 50053 '$((requests_per_window / 8))' '$((warmup / 8))' \"key-\$i\" >${guest_run_dir}/grpc-stable-\$i.out || status=1
         done
         cat ${guest_run_dir}/grpc-stable-*.out || status=1
         exit \"\$status\"" >"${output}"
      ;;
    burst)
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "rm -f -- ${guest_run_dir}/grpc-burst-*.out
         pids=()
         for i in \$(seq 1 '${burst_clients}'); do
            '${guest_grpc_harness}' client '${client_ip}' 50053 '$((requests_per_window / burst_clients))' '$((warmup / burst_clients))' '${grpc_payload}' >${guest_run_dir}/grpc-burst-\$i.out &
            pids+=(\"\$!\")
         done
         status=0
         for pid in \"\${pids[@]}\"; do
           wait \"\$pid\" || status=1
         done
         cat ${guest_run_dir}/grpc-burst-*.out || status=1
         exit \"\$status\"" >"${output}"
      ;;
    shifting-hot-key)
      if (( window <= windows / 2 )); then
        shifting_payload="${grpc_payload}"
      else
        shifting_payload="${grpc_shift_payload}"
      fi
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "'${guest_grpc_harness}' client '${client_ip}' 50053 '${requests_per_window}' '${warmup}' '${shifting_payload}'" >"${output}"
      ;;
    low-hit-rate)
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "rm -f -- ${guest_run_dir}/grpc-low-*.out
         pids=()
         for i in \$(seq 1 8); do
            '${guest_grpc_harness}' client '${client_ip}' 50053 '$((requests_per_window / 8))' '$((warmup / 8))' \"unique-\$i\" >${guest_run_dir}/grpc-low-\$i.out &
            pids+=(\"\$!\")
         done
         status=0
         for pid in \"\${pids[@]}\"; do
           wait \"\$pid\" || status=1
         done
         cat ${guest_run_dir}/grpc-low-*.out || status=1
         exit \"\$status\"" >"${output}"
      ;;
    *)
      guest_run_tracked_process "${client_ip}" "${state_file}" \
        "'${guest_grpc_harness}' client '${client_ip}' 50053 '${requests_per_window}' '${warmup}' '${grpc_payload}'" >"${output}"
      ;;
  esac
}

start_dynamic_controller() {
  local audit_log="$1"
  coproc DYNAMIC_POLICY {
    "${controller}" --dry-run --initial-mode bypass --initial-epoch 1 \
      --window-size 2 --required-windows 2 --cooldown-ms 0 \
      --min-window-requests 50 \
      --cache-enter-hit-ratio 0.35 --cache-exit-hit-ratio 0.20 \
      --client-enter-p95-us 5000 --client-exit-p95-us 3000 \
      --dual-enter-backend-qps 1200 --dual-exit-backend-qps 800 \
      --bypass-error-rate 0.05 --audit-log "${audit_log}"
  }
  dynamic_out_fd="${DYNAMIC_POLICY[0]}"
  dynamic_in_fd="${DYNAMIC_POLICY[1]}"
  dynamic_pid="${DYNAMIC_POLICY_PID}"
  local startup
  IFS= read -r startup <&"${dynamic_out_fd}"
  [[ "${startup}" == dynamic_cache_publish* ]]
}

read_dynamic_decision() {
  local line
  while IFS= read -r line <&"${dynamic_out_fd}"; do
    [[ "${line}" == dynamic_cache_decision* ]] || continue
    printf '%s\n' "${line}"
    return 0
  done
  return 1
}

printf 'policy,workload,round,window,dns_success,dns_failed,dns_qps,dns_p95_us,grpc_success,grpc_failed,grpc_qps,grpc_p95_us,backend_requests,backend_qps,dns_hits,dns_misses,grpc_hits,grpc_misses,dns_client_cache_hits,dns_server_cache_hits,grpc_client_cache_hits,grpc_server_cache_hits,grpc_backend_fallback,applied_mode,applied_epoch,next_mode,next_epoch\n' \
  >"${out_dir}/windows.csv"
printf 'policy,workload,round,dns_success,dns_failed,dns_qps,grpc_success,grpc_failed,grpc_qps,backend_requests,max_dns_p95_us,max_grpc_p95_us,final_mode,final_epoch\n' \
  >"${out_dir}/runs.csv"

for policy in "${policies[@]}"; do
  for workload in "${workloads[@]}"; do
    for round in $(seq 1 "${rounds}"); do
      label="${policy}-${workload}-r${round}"
      echo "running ${label}"
      start_monitors "${label}"
      current_mode="${policy}"
      current_epoch=1
      if [[ "${policy}" == dynamic ]]; then
        current_mode=bypass
        start_dynamic_controller "${out_dir}/decisions/${label}.audit.log"
      fi
      apply_mode "${current_mode}" "${current_epoch}" "${label}-initial"

      run_dns_success=0
      run_dns_failed=0
      run_grpc_success=0
      run_grpc_failed=0
      run_load_elapsed_ns=0
      run_backend_start="$(backend_count)"
      [[ "${run_backend_start}" =~ ^[0-9]+$ ]] || {
        echo "invalid DNS backend counter at start of ${label}" >&2
        exit 1
      }
      max_dns_p95=0
      max_grpc_p95=0

      dns_client_stats_before="$(host_dns_stats)"
      dns_server_stats_before="$(guest_dns_stats)"
      grpc_client_stats_before="$(client_grpc_stats)"
      grpc_server_stats_before="$(server_grpc_stats)"
      run_grpc_fallback_start="$(field "${grpc_server_stats_before}" fallback)"
      for window in $(seq 1 "${windows}"); do
        applied_mode="${current_mode}"
        applied_epoch="${current_epoch}"
        raw_prefix="${out_dir}/raw/${label}-w${window}"
        backend_before="$(backend_count)"
        window_started="$(date +%s%N)"
        run_dns_load "${workload}" "${raw_prefix}.dns" "${window}" &
        dns_job=$!
        run_grpc_load "${workload}" "${raw_prefix}.grpc" "${window}" &
        grpc_job=$!
        set +e
        wait "${dns_job}"
        dns_load_rc=$?
        wait "${grpc_job}"
        grpc_load_rc=$?
        set -e
        window_finished="$(date +%s%N)"
        backend_after="$(backend_count)"
        [[ "${backend_before}" =~ ^[0-9]+$ &&
           "${backend_after}" =~ ^[0-9]+$ ]] || {
          echo "invalid DNS backend counter in ${label} window ${window}" >&2
          exit 1
        }
        if (( backend_after < backend_before )); then
          echo "DNS backend counter regressed in ${label} window ${window}" >&2
          exit 1
        fi

        dns_result="$(aggregate_output "${raw_prefix}.dns" success)"
        grpc_result="$(aggregate_output "${raw_prefix}.grpc" count)"
        printf 'dns_load_rc=%s\ngrpc_load_rc=%s\n' \
          "${dns_load_rc}" "${grpc_load_rc}" >"${raw_prefix}.status"
        [[ -s "${raw_prefix}.dns" && -s "${raw_prefix}.grpc" ]] || {
          echo "load output missing for ${label} window ${window}" >&2
          exit 1
        }
        dns_success="$(field "${dns_result}" success)"
        dns_failed="$(field "${dns_result}" failed)"
        dns_p95="$(field "${dns_result}" p95_us)"
        grpc_success="$(field "${grpc_result}" success)"
        grpc_failed="$(field "${grpc_result}" failed)"
        grpc_p95="$(field "${grpc_result}" p95_us)"
        if (( dns_load_rc != 0 || grpc_load_rc != 0 )); then
          echo "load task failed for ${label} window ${window}: dns_rc=${dns_load_rc} grpc_rc=${grpc_load_rc}; raw outputs retained" >&2
          exit 1
        fi
        elapsed_ns=$((window_finished - window_started))
        dns_qps="$(awk -v count="${dns_success}" -v ns="${elapsed_ns}" \
          'BEGIN {printf "%.2f", count * 1000000000 / ns}')"
        grpc_qps="$(awk -v count="${grpc_success}" -v ns="${elapsed_ns}" \
          'BEGIN {printf "%.2f", count * 1000000000 / ns}')"
        backend_delta=$((backend_after - backend_before))

        dns_client_stats_after="$(host_dns_stats)"
        dns_server_stats_after="$(guest_dns_stats)"
        grpc_client_stats_after="$(client_grpc_stats)"
        grpc_server_stats_after="$(server_grpc_stats)"
        dns_hit_delta=$(( \
          $(delta_field "${dns_client_stats_after}" "${dns_client_stats_before}" cache_hit) + \
          $(delta_field "${dns_client_stats_after}" "${dns_client_stats_before}" shadow_hit) ))
        dns_miss_delta=$(( \
          $(delta_field "${dns_client_stats_after}" "${dns_client_stats_before}" cache_miss) + \
          $(delta_field "${dns_client_stats_after}" "${dns_client_stats_before}" shadow_miss) ))
        dns_client_actual_hit_delta="$(delta_field "${dns_client_stats_after}" "${dns_client_stats_before}" cache_hit)"
        dns_server_actual_hit_delta="$(delta_field "${dns_server_stats_after}" "${dns_server_stats_before}" cache_hit)"
        grpc_hit_delta=$(( \
          $(delta_field "${grpc_client_stats_after}" "${grpc_client_stats_before}" cache_hit) + \
          $(delta_field "${grpc_client_stats_after}" "${grpc_client_stats_before}" shadow_hit) ))
        grpc_miss_delta=$(( \
          $(delta_field "${grpc_client_stats_after}" "${grpc_client_stats_before}" policy_miss) + \
          $(delta_field "${grpc_client_stats_after}" "${grpc_client_stats_before}" response_cache_miss) + \
          $(delta_field "${grpc_client_stats_after}" "${grpc_client_stats_before}" shadow_miss) ))
        grpc_client_actual_hit_delta="$(delta_field "${grpc_client_stats_after}" "${grpc_client_stats_before}" cache_hit)"
        grpc_server_actual_hit_delta="$(delta_field "${grpc_server_stats_after}" "${grpc_server_stats_before}" cache_hit)"
        grpc_backend_delta="$(delta_field "${grpc_server_stats_after}" "${grpc_server_stats_before}" fallback)"
        grpc_runtime_error_delta=$(( \
          $(delta_field "${grpc_client_stats_after}" "${grpc_client_stats_before}" runtime_map_error) + \
          $(delta_field "${grpc_server_stats_after}" "${grpc_server_stats_before}" runtime_map_error) ))
        if [[ "${grpc_runtime_error_delta}" -ne 0 ]]; then
          echo "gRPC runtime map error in ${label} window ${window}" >&2
          exit 1
        fi
        backend_requests=$((backend_delta + grpc_backend_delta))
        backend_qps="$(awk -v count="${backend_requests}" -v ns="${elapsed_ns}" \
          'BEGIN {printf "%.2f", count * 1000000000 / ns}')"
        total_requests=$((dns_success + dns_failed + grpc_success + grpc_failed))
        total_failed=$((dns_failed + grpc_failed))
        error_rate="$(awk -v failed="${total_failed}" -v total="${total_requests}" \
          'BEGIN {if (total > 0) printf "%.6f", failed / total; else print "1.000000"}')"

        if [[ "${policy}" == dynamic ]]; then
          timestamp_ms=$((window_finished / 1000000))
          printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "${timestamp_ms}" "${dns_hit_delta}" "${dns_miss_delta}" \
            "${dns_p95}" "${grpc_hit_delta}" "${grpc_miss_delta}" \
            "${grpc_p95}" "${backend_qps}" "${error_rate}" \
            >&"${dynamic_in_fd}"
          decision="$(read_dynamic_decision)"
          printf '%s\n' "${decision}" \
            >>"${out_dir}/decisions/${label}.stream.log"
          if [[ "$(field "${decision}" changed)" == 1 ]]; then
            next_mode="$(field "${decision}" mode)"
            next_epoch="$(field "${decision}" epoch)"
            apply_mode "${next_mode}" "${next_epoch}" \
              "${label}-w${window}" "${current_mode}" "${current_epoch}"
            current_mode="${next_mode}"
            current_epoch="${next_epoch}"
          fi
        fi

        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
          "${policy}" "${workload}" "${round}" "${window}" \
          "${dns_success}" "${dns_failed}" "${dns_qps}" "${dns_p95}" \
          "${grpc_success}" "${grpc_failed}" "${grpc_qps}" "${grpc_p95}" \
          "${backend_requests}" "${backend_qps}" \
          "${dns_hit_delta}" "${dns_miss_delta}" \
          "${grpc_hit_delta}" "${grpc_miss_delta}" \
          "${dns_client_actual_hit_delta}" "${dns_server_actual_hit_delta}" \
          "${grpc_client_actual_hit_delta}" "${grpc_server_actual_hit_delta}" \
          "${grpc_backend_delta}" \
          "${applied_mode}" "${applied_epoch}" \
          "${current_mode}" "${current_epoch}" >>"${out_dir}/windows.csv"

        run_dns_success=$((run_dns_success + dns_success))
        run_dns_failed=$((run_dns_failed + dns_failed))
        run_grpc_success=$((run_grpc_success + grpc_success))
        run_grpc_failed=$((run_grpc_failed + grpc_failed))
        run_load_elapsed_ns=$((run_load_elapsed_ns + elapsed_ns))
        max_dns_p95="$(awk -v old="${max_dns_p95}" -v new="${dns_p95}" \
          'BEGIN {print (new > old ? new : old)}')"
        max_grpc_p95="$(awk -v old="${max_grpc_p95}" -v new="${grpc_p95}" \
          'BEGIN {print (new > old ? new : old)}')"
        dns_client_stats_before="${dns_client_stats_after}"
        dns_server_stats_before="${dns_server_stats_after}"
        grpc_client_stats_before="${grpc_client_stats_after}"
        grpc_server_stats_before="${grpc_server_stats_after}"
      done

      run_backend_end="$(backend_count)"
      [[ "${run_backend_end}" =~ ^[0-9]+$ ]] &&
        (( run_backend_end >= run_backend_start )) || {
        echo "invalid DNS backend counter at end of ${label}" >&2
        exit 1
      }
      run_grpc_fallback_end="$(field "${grpc_server_stats_after}" fallback)"
      run_dns_qps="$(awk -v count="${run_dns_success}" -v ns="${run_load_elapsed_ns}" \
        'BEGIN {printf "%.2f", count * 1000000000 / ns}')"
      run_grpc_qps="$(awk -v count="${run_grpc_success}" -v ns="${run_load_elapsed_ns}" \
        'BEGIN {printf "%.2f", count * 1000000000 / ns}')"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${policy}" "${workload}" "${round}" \
        "${run_dns_success}" "${run_dns_failed}" "${run_dns_qps}" \
        "${run_grpc_success}" "${run_grpc_failed}" "${run_grpc_qps}" \
        "$((run_backend_end - run_backend_start + run_grpc_fallback_end - run_grpc_fallback_start))" \
        "${max_dns_p95}" "${max_grpc_p95}" \
        "${current_mode}" "${current_epoch}" >>"${out_dir}/runs.csv"

      if [[ "${policy}" == dynamic ]]; then
        stop_dynamic_controller
      fi
      stop_monitors || {
        echo "monitor lifecycle cleanup failed for ${label}" >&2
        exit 1
      }
    done
  done
done

python3 - "${out_dir}/runs.csv" "${out_dir}/summary.csv" \
  "${out_dir}/summary.md" <<'PY'
import csv
import statistics
import sys
from collections import defaultdict

source, summary_csv, summary_md = sys.argv[1:4]
groups = defaultdict(list)
with open(source, newline="", encoding="utf-8") as handle:
    for row in csv.DictReader(handle):
        groups[(row["policy"], row["workload"])].append(row)

fields = [
    "policy", "workload", "rounds", "median_dns_qps", "median_grpc_qps",
    "median_backend_requests", "max_dns_failed", "max_grpc_failed",
    "median_dns_p95_us", "median_grpc_p95_us",
]
rows = []
for (policy, workload), values in sorted(groups.items()):
    rows.append({
        "policy": policy,
        "workload": workload,
        "rounds": len(values),
        "median_dns_qps": f"{statistics.median(float(v['dns_qps']) for v in values):.2f}",
        "median_grpc_qps": f"{statistics.median(float(v['grpc_qps']) for v in values):.2f}",
        "median_backend_requests": f"{statistics.median(int(v['backend_requests']) for v in values):.0f}",
        "max_dns_failed": max(int(v["dns_failed"]) for v in values),
        "max_grpc_failed": max(int(v["grpc_failed"]) for v in values),
        "median_dns_p95_us": f"{statistics.median(float(v['max_dns_p95_us']) for v in values):.2f}",
        "median_grpc_p95_us": f"{statistics.median(float(v['max_grpc_p95_us']) for v in values):.2f}",
    })

with open(summary_csv, "w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)

with open(summary_md, "w", encoding="utf-8") as handle:
    handle.write("# OpenStack Dynamic Cache Campaign\n\n")
    handle.write("| policy | workload | rounds | DNS QPS | gRPC QPS | backend requests | DNS failed | gRPC failed | DNS p95 us | gRPC p95 us |\n")
    handle.write("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n")
    for row in rows:
        handle.write(
            f"| {row['policy']} | {row['workload']} | {row['rounds']} | "
            f"{row['median_dns_qps']} | {row['median_grpc_qps']} | "
            f"{row['median_backend_requests']} | {row['max_dns_failed']} | "
            f"{row['max_grpc_failed']} | {row['median_dns_p95_us']} | "
            f"{row['median_grpc_p95_us']} |\n"
        )
    handle.write("\nMedians use all formal rounds. Raw windows, decisions, monitor logs, and cleanup audit are retained beside this file.\n")
PY

cat "${out_dir}/summary.md"
