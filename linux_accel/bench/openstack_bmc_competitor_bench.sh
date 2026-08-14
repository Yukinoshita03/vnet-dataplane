#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_dir="${1:?usage: $0 ARTIFACT_DIR [smoke|formal]}"
profile="${2:-formal}"

ssh_key="${SSH_KEY:-/Users/tankaiwen/vnet-dataplane/openstack-deployment/config/deploy_key}"
node1_target="${NODE1_SSH:-ading@10.115.24.245}"
node2_target="${NODE2_SSH:-ading2@10.115.24.114}"
node3_target="${NODE3_SSH:-ading3@10.115.24.40}"
openstack_status="${OPENSTACK_STATUS:-/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/openstack-status.sh}"
offline_deb_dir="${OFFLINE_DEB_DIR:-/Users/tankaiwen/vnet-dataplane/openstack-deployment/offline/apt/debs}"
qga_exec_local="${repo_root}/tools/openstack_qga_exec.sh"
qga_copy_local="${repo_root}/tools/openstack_qga_copy_to.sh"

release_root="${RELEASE_ROOT:-/opt/competitor-bench/releases/competitor-preflight-20260813-173626}"
bmc_dir="${BMC_DIR:-${release_root}/bmc-modern-v10}"
linux_dir="${LINUX_DIR:-${release_root}/linux-accel-bmc-target-v6}"
client_server="${CLIENT_SERVER:-linux-accel-client}"
backend_server="${BACKEND_SERVER:-linux-accel-backend}"
adapter_unit="${ADAPTER_UNIT:-linux-accel-openstack-tap-accel@96696c4a-5746-43ab-8137-241952309dac.service}"
backend_ip="${BACKEND_IP:-192.168.110.13}"
server_port="${SERVER_PORT:-11211}"
population="${POPULATION:-65536}"
hot_keys="${HOT_KEYS:-4096}"
zipf="${ZIPF:-0.99}"

case "${profile}" in
  smoke)
    repetitions="${REPETITIONS:-1}"
    threads="${THREADS:-1}"
    requests_per_thread="${REQUESTS_PER_THREAD:-1000}"
    warmup="${WARMUP:-50}"
    population="${POPULATION:-4096}"
    hot_keys="${HOT_KEYS:-1024}"
    ;;
  formal)
    repetitions="${REPETITIONS:-5}"
    threads="${THREADS:-2}"
    requests_per_thread="${REQUESTS_PER_THREAD:-25000}"
    warmup="${WARMUP:-1000}"
    ;;
  *)
    echo "profile must be smoke or formal" >&2
    exit 2
    ;;
esac

run_id="$(basename "${artifact_dir}" | tr -cd 'A-Za-z0-9_.-')"
short_id="$(printf '%s' "${run_id}" | shasum -a 256 | cut -c1-10)"
node1_run="/tmp/linux-accel-openstack-bmc-${short_id}"
node2_run="/tmp/linux-accel-openstack-bmc-${short_id}"
guest_run="/run/linux-accel-openstack-bmc-${short_id}"
backend_unit="linux-accel-bmc-backend-${short_id}.service"

client_instance=""
backend_instance=""
client_port_id=""
backend_port_id=""
client_mac=""
backend_mac=""
client_tap=""
backend_tap=""
client_initial_status=""
backend_initial_status=""
client_started_by_run=false
backend_started_by_run=false
adapter_was_active=false
backend_service_started=false
loader_unit=""
loader_started=false
environment_restored=false

mkdir -p "${artifact_dir}"/{health,correctness,cases,logs,system,analysis}

verify_local_sha256()
{
  local expected="$1" path="$2" actual
  actual="$(shasum -a 256 "${path}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "SHA-256 mismatch for ${path}: ${actual}" >&2
    return 1
  fi
}

shell_quote()
{
  printf '%q' "$1"
}

target_for()
{
  case "$1" in
    node1) printf '%s' "${node1_target}" ;;
    node2) printf '%s' "${node2_target}" ;;
    node3) printf '%s' "${node3_target}" ;;
    *) return 2 ;;
  esac
}

remote()
{
  local node="$1"
  shift
  ssh -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    "$(target_for "${node}")" "$@"
}

copy_to_host()
{
  local source="$1" node="$2" destination="$3"
  scp -i "${ssh_key}" -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new "${source}" \
    "$(target_for "${node}"):${destination}"
}

openstack_cli()
{
  local command="source /root/openrc; timeout 20 openstack $*"
  remote node1 "sudo bash -lc $(shell_quote "${command}")"
}

openstack_capture()
{
  local output="$1" attempt
  shift
  for attempt in 1 2 3; do
    if openstack_cli "$@" >"${output}.attempt-${attempt}" 2>&1; then
      cp "${output}.attempt-${attempt}" "${output}"
      return 0
    fi
    sleep 2
  done
  echo "OpenStack command failed after three attempts: $*" >&2
  return 1
}

client_guest()
{
  local command="$1"
  remote node1 "/tmp/linux-accel-qga-exec.sh ${client_instance} $(shell_quote "${command}")"
}

backend_guest()
{
  local command="$1"
  remote node2 "/tmp/linux-accel-qga-exec.sh ${backend_instance} $(shell_quote "${command}")"
}

copy_to_guest()
{
  local node="$1" instance="$2" source="$3" destination="$4" mode="$5"
  remote "${node}" "/tmp/linux-accel-qga-copy-to.sh ${instance} $(shell_quote "${source}") $(shell_quote "${destination}") ${mode}"
}

wait_server_status()
{
  local server="$1" expected="$2" attempts="${3:-90}"
  for unused in $(seq 1 "${attempts}"); do
    if [[ "$(openstack_cli server show "${server}" -f value -c status 2>/dev/null | tr -d '[:space:]')" == "${expected}" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_guest_agent()
{
  local node="$1" instance="$2"
  for unused in $(seq 1 90); do
    if remote "${node}" "sudo virsh qemu-agent-command ${instance} '{\"execute\":\"guest-ping\"}'" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

tap_external_id()
{
  local node="$1" tap="$2" key="$3"
  remote "${node}" "sudo ovs-vsctl --if-exists get Interface ${tap} external_ids:${key} 2>/dev/null | tr -d '\"[:space:]'"
}

stop_started_server()
{
  local node="$1" server="$2" instance="$3"
  openstack_cli server stop "${server}" >/dev/null 2>&1 || true
  for unused in $(seq 1 10); do
    if [[ "$(remote "${node}" "virsh domstate ${instance}" 2>/dev/null | tr -d '\r')" == "shut off" ]]; then
      return 0
    fi
    sleep 1
  done
  remote "${node}" \
    "test \"\$(virsh domstate ${instance})\" = running && sudo virsh shutdown ${instance} || true"
  for unused in $(seq 1 30); do
    if [[ "$(remote "${node}" "virsh domstate ${instance}" 2>/dev/null | tr -d '\r')" == "shut off" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "failed to restore ${server}/${instance} to SHUTOFF" >&2
  return 1
}

wait_tap_binding()
{
  local node="$1" tap="$2" port_id="$3" mac="$4"
  local actual_port actual_mac
  for unused in $(seq 1 90); do
    if remote "${node}" "test -e /sys/class/net/${tap}" >/dev/null 2>&1; then
      actual_port="$(tap_external_id "${node}" "${tap}" iface-id || true)"
      actual_mac="$(tap_external_id "${node}" "${tap}" attached-mac | tr '[:upper:]' '[:lower:]' || true)"
      if [[ "${actual_port}" == "${port_id}" && "${actual_mac}" == "${mac}" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

capture_kubernetes()
{
  local output="$1"
  : >"${output}"
  for node in node1 node2 node3; do
    remote "${node}" \
      'for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
      | sed "s/^/${node} /" >>"${output}"
  done
  if grep -q '=active$' "${output}"; then
    echo "Kubernetes must remain stopped" >&2
    return 1
  fi
}

capture_openstack_status()
{
  local output="$1" attempt inventory
  inventory="${output}.inventory"
  local services="${inventory}.services.json"
  timeout 20 "${openstack_status}" >"${output}.full-status" 2>&1 || true
  : >"${output}"
  for attempt in 1 2 3; do
    if {
      printf 'Horizon '; curl -fsS -o /dev/null --connect-timeout 3 \
        -w '%{http_code}\n' http://10.115.24.250/auth/login/;
      printf 'Keystone '; curl -fsS -o /dev/null --connect-timeout 3 \
        -w '%{http_code}\n' http://10.115.24.250:5000/v3;
      printf 'Glance '; curl -fsS -o /dev/null --connect-timeout 3 \
        -w '%{http_code}\n' http://10.115.24.250:9292/;
      printf 'Nova '; curl -fsS -o /dev/null --connect-timeout 3 \
        -w '%{http_code}\n' http://10.115.24.250:8774/;
      printf 'Placement '; curl -fsS -o /dev/null --connect-timeout 3 \
        -w '%{http_code}\n' http://10.115.24.250:8780/;
      printf 'Neutron '; curl -fsS -o /dev/null --connect-timeout 3 \
        -w '%{http_code}\n' http://10.115.24.250:9696/healthcheck;
    } >"${output}.api-attempt-${attempt}" 2>&1 &&
       remote node1 \
         "timeout 15 sudo bash -lc 'source /root/openrc; openstack compute service list -f json'" \
         >"${services}.attempt-${attempt}" 2>&1; then
      cp "${output}.api-attempt-${attempt}" "${output}"
      cp "${services}.attempt-${attempt}" "${services}"
      break
    fi
    sleep 2
  done
  test -s "${output}"
  grep -q '^Horizon 200$' "${output}"
  grep -q '^Keystone 200$' "${output}"
  grep -q '^Glance 300$' "${output}"
  grep -q '^Nova 200$' "${output}"
  grep -q '^Placement 200$' "${output}"
  grep -q '^Neutron 200$' "${output}"
  for node in node1 node2 node3; do
    remote "${node}" \
      'for unit in haproxy mariadb rabbitmq-server nova-compute neutron-server neutron-ovn-metadata-agent ovn-controller libvirtd; do test "$(systemctl is-active "$unit")" = active || exit 1; done; test "$(sudo ovn-appctl -t ovn-controller connection-status)" = connected' \
      >"${output}.${node}-units"
  done
  python3 - "${services}" <<'PY'
import json
import sys

services = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(services) == 9, len(services)
assert all(item.get("Status") == "enabled" and item.get("State") == "up" for item in services)
PY
}

cleanup_loader()
{
  local log_path="${1:-}"
  if ${loader_started} && [[ -n "${loader_unit}" ]]; then
    remote node1 "sudo systemctl stop ${loader_unit}" >/dev/null 2>&1 || true
    if [[ -n "${log_path}" ]]; then
      remote node1 "sudo journalctl --no-pager -o cat -u ${loader_unit}" \
        >"${log_path}" 2>&1 || true
    fi
    loader_started=false
    loader_unit=""
  fi
}

stop_backend_service()
{
  if ${backend_service_started} && [[ -n "${backend_instance}" ]]; then
    backend_guest "systemctl stop ${backend_unit} 2>/dev/null || true" \
      >/dev/null 2>&1 || true
    backend_guest "journalctl --no-pager -o cat -u ${backend_unit}" \
      >"${artifact_dir}/logs/backend-service.log" 2>&1 || true
    backend_service_started=false
  fi
}

restore_environment()
{
  ${environment_restored} && return 0
  set +e
  cleanup_loader "${artifact_dir}/logs/loader-cleanup.log"
  stop_backend_service
  if [[ -n "${client_instance}" ]]; then
    client_guest "rm -rf ${guest_run}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${backend_instance}" ]]; then
    backend_guest "rm -rf ${guest_run}" >/dev/null 2>&1 || true
  fi
  if ${client_started_by_run}; then
    stop_started_server node1 "${client_server}" "${client_instance}" \
      >/dev/null 2>&1 || true
    client_started_by_run=false
  fi
  if ${backend_started_by_run}; then
    stop_started_server node2 "${backend_server}" "${backend_instance}" \
      >/dev/null 2>&1 || true
    backend_started_by_run=false
  fi
  if ${adapter_was_active}; then
    remote node1 "sudo systemctl start ${adapter_unit}" >/dev/null 2>&1 || true
  fi
  remote node1 "rm -rf ${node1_run}" >/dev/null 2>&1 || true
  remote node2 "rm -rf ${node2_run}" >/dev/null 2>&1 || true
  environment_restored=true
  set -e
}

on_exit()
{
  local status="$1"
  trap - EXIT INT TERM
  restore_environment
  exit "${status}"
}
trap 'on_exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

metric_from_log()
{
  local file="$1" name="$2"
  awk -v wanted="${name}" \
    '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]==wanted){print a[2]; exit}}}' \
    "${file}"
}

memcached_counter()
{
  local name="$1"
  backend_guest \
    "${guest_run}/memcached_udp_zipf_bench --server ${backend_ip}:${server_port} --population ${population} --hot-keys ${hot_keys} --zipf ${zipf} --stats" \
    | awk -v wanted="${name}" '$1=="STAT" && $2==wanted {gsub(/\r/,"",$3); print $3; exit}'
}

tap_packets()
{
  local node="$1" tap="$2" direction="$3"
  remote "${node}" "ip -s link show dev ${tap}" | \
    awk -v wanted="${direction}:" '$1==wanted {getline; print $2; exit}'
}

wait_xdp()
{
  local need_tc="$1"
  for unused in $(seq 1 50); do
    if remote node1 "sudo bpftool net show dev ${client_tap}" 2>/dev/null | grep -q 'generic id'; then
      if [[ "${need_tc}" == 0 ]] || \
        remote node1 "tc filter show dev ${client_tap} egress" 2>/dev/null | grep -q 'bmc_tx_filter'; then
        return 0
      fi
    fi
    sleep 0.1
  done
  return 1
}

set_mode()
{
  local mode="$1" label="$2"
  cleanup_loader "${artifact_dir}/logs/${label}-previous-loader.log"
  if remote node1 "sudo bpftool net show dev ${client_tap}" 2>/dev/null | grep -Eq '(generic|native|offload) id'; then
    echo "unexpected XDP owner on ${client_tap}" >&2
    return 1
  fi
  case "${mode}" in
    nohook)
      ;;
    bmc)
      loader_unit="linux-accel-bmc-${short_id}-${label}.service"
      remote node1 \
        "sudo systemd-run --unit=${loader_unit} --collect --property=Type=simple -- ${bmc_dir}/bmc_loader --dev ${client_tap} --bpf-object ${bmc_dir}/bmc_kern.o --xdp-mode generic" \
        >"${artifact_dir}/logs/${label}-start.log"
      loader_started=true
      wait_xdp 1
      ;;
    linux-accel)
      loader_unit="linux-accel-udp-${short_id}-${label}.service"
      remote node1 \
        "sudo systemd-run --unit=${loader_unit} --collect --property=Type=simple -- ${linux_dir}/udp_fastpath --policy-file ${node1_run}/linux-accel-policy.conf --bpf-object ${linux_dir}/udp_fastpath.bpf.o --xdp-mode generic" \
        >"${artifact_dir}/logs/${label}-start.log"
      loader_started=true
      wait_xdp 0
      ;;
    *)
      return 2
      ;;
  esac
  {
    remote node1 "sudo bpftool net show dev ${client_tap}" || true
    remote node1 "tc filter show dev ${client_tap} egress" || true
  } >"${artifact_dir}/logs/${label}-attachments.txt" 2>&1
}

client_command()
{
  printf '%s' \
    "${guest_run}/memcached_udp_zipf_bench --server ${backend_ip}:${server_port} --population ${population} --hot-keys ${hot_keys} --zipf ${zipf}"
}

warm_bmc()
{
  local label="$1" before after
  before="$(memcached_counter cmd_get)"
  client_guest "$(client_command) --warm-all" \
    >"${artifact_dir}/logs/${label}-bmc-warm.log"
  after="$(memcached_counter cmd_get)"
  test "$((after - before))" -eq "${hot_keys}"
}

correctness()
{
  local mode="$1" before after delta expected label="correctness-${mode}"
  set_mode "${mode}" "${label}"
  if [[ "${mode}" == bmc ]]; then
    warm_bmc "${label}"
  elif [[ "${mode}" == nohook ]]; then
    client_guest "$(client_command) --warm-all" \
      >"${artifact_dir}/logs/${label}-warm.log"
  fi
  before="$(memcached_counter cmd_get)"
  client_guest "$(client_command) --threads 1 --requests 64 --warmup 0 --seed 42" \
    >"${artifact_dir}/correctness/${mode}.log"
  after="$(memcached_counter cmd_get)"
  delta=$((after - before))
  if [[ "${mode}" == nohook ]]; then
    expected=64
    test "${delta}" -eq 64
  else
    expected=-1
    test "${delta}" -gt 0
    test "${delta}" -lt 64
  fi
  grep -q 'failed=0' "${artifact_dir}/correctness/${mode}.log"
  printf 'mode=%s backend_delta=%s expected=%s\n' \
    "${mode}" "${delta}" "${expected}" \
    >"${artifact_dir}/correctness/${mode}-backend.txt"
  cleanup_loader "${artifact_dir}/logs/${label}-loader.log"
}

run_case()
{
  local mode="$1" repetition="$2" label="${mode}-r${repetition}"
  local case_dir="${artifact_dir}/cases/${label}"
  local before_cmd after_cmd before_rx after_rx before_tx after_tx
  mkdir -p "${case_dir}"
  set_mode "${mode}" "${label}"
  if [[ "${mode}" == bmc ]]; then
    warm_bmc "${label}"
  elif [[ "${mode}" == nohook ]]; then
    client_guest "$(client_command) --warm-all" \
      >"${artifact_dir}/logs/${label}-warm.log"
  fi
  client_guest \
    "$(client_command) --threads ${threads} --requests ${warmup} --warmup 0 --seed 77" \
    >/dev/null
  before_cmd="$(memcached_counter cmd_get)"
  before_rx="$(tap_packets node2 "${backend_tap}" RX)"
  before_tx="$(tap_packets node2 "${backend_tap}" TX)"
  printf '%s\n' "${before_cmd}" >"${case_dir}/backend-before.txt"
  remote node1 'cat /proc/stat' >"${case_dir}/proc-stat-before.txt"
  remote node1 'cat /proc/softirqs' >"${case_dir}/softirqs-before.txt"
  remote node1 'cat /proc/net/softnet_stat' >"${case_dir}/softnet-before.txt"
  remote node1 'cat /proc/net/snmp' >"${case_dir}/snmp-before.txt"
  remote node2 'cat /proc/stat' >"${case_dir}/node2-proc-stat-before.txt"
  remote node1 "ip -s link show dev ${client_tap}" >"${case_dir}/client-tap-before.txt"
  remote node2 "ip -s link show dev ${backend_tap}" >"${case_dir}/backend-tap-before.txt"
  client_guest \
    "$(client_command) --threads ${threads} --requests ${requests_per_thread} --warmup 0 --seed 202108" \
    >"${case_dir}/client.log"
  after_cmd="$(memcached_counter cmd_get)"
  after_rx="$(tap_packets node2 "${backend_tap}" RX)"
  after_tx="$(tap_packets node2 "${backend_tap}" TX)"
  printf '%s\n' "${after_cmd}" >"${case_dir}/backend-after.txt"
  remote node1 'cat /proc/stat' >"${case_dir}/proc-stat-after.txt"
  remote node1 'cat /proc/softirqs' >"${case_dir}/softirqs-after.txt"
  remote node1 'cat /proc/net/softnet_stat' >"${case_dir}/softnet-after.txt"
  remote node1 'cat /proc/net/snmp' >"${case_dir}/snmp-after.txt"
  remote node2 'cat /proc/stat' >"${case_dir}/node2-proc-stat-after.txt"
  remote node1 "ip -s link show dev ${client_tap}" >"${case_dir}/client-tap-after.txt"
  remote node2 "ip -s link show dev ${backend_tap}" >"${case_dir}/backend-tap-after.txt"
  printf 'mode=%s repetition=%s backend_delta=%s server_rx_delta=%s backend_tap_tx_delta=%s\n' \
    "${mode}" "${repetition}" "$((after_cmd - before_cmd))" \
    "$((after_rx - before_rx))" "$((after_tx - before_tx))" \
    >"${case_dir}/metadata.txt"
  grep -q 'failed=0' "${case_dir}/client.log"
  cleanup_loader "${case_dir}/loader.log"
}

# Read-only baseline gates before changing VM or adapter state.
test -r "${ssh_key}"
test -x "${qga_exec_local}"
test -x "${qga_copy_local}"
test -x "${openstack_status}"
verify_local_sha256 \
  3872214a9bc723123c1a78831c99f20416a5fa758ae1ebc682fd9af438759195 \
  "${offline_deb_dir}/memcached_1.6.40-1ubuntu0.1_amd64.deb"
verify_local_sha256 \
  8c14223ae11b2bba96afa0a1a08206cc63ad220d999e90a119f7c76549c62e16 \
  "${offline_deb_dir}/libevent-2.1-7t64_2.1.12-stable-10build2_amd64.deb"
verify_local_sha256 \
  ff589ea3f181b89dd76b0240f79c59ac2f13f24e2053f624f774f596c7ef7897 \
  "${offline_deb_dir}/liblua5.4-0_5.4.8-1build1_amd64.deb"
capture_openstack_status "${artifact_dir}/health/openstack-before.txt"
capture_kubernetes "${artifact_dir}/health/kubernetes-before.txt"

openstack_capture "${artifact_dir}/health/client-server-before.json" \
  server show "${client_server}" -f json
openstack_capture "${artifact_dir}/health/backend-server-before.json" \
  server show "${backend_server}" -f json
openstack_capture "${artifact_dir}/health/client-ports-before.json" \
  port list --server "${client_server}" -f json
openstack_capture "${artifact_dir}/health/backend-ports-before.json" \
  port list --server "${backend_server}" -f json

test "$(jq 'length' "${artifact_dir}/health/client-ports-before.json")" -eq 1
test "$(jq 'length' "${artifact_dir}/health/backend-ports-before.json")" -eq 1
client_instance="$(jq -r '."OS-EXT-SRV-ATTR:instance_name"' "${artifact_dir}/health/client-server-before.json")"
backend_instance="$(jq -r '."OS-EXT-SRV-ATTR:instance_name"' "${artifact_dir}/health/backend-server-before.json")"
client_initial_status="$(jq -r '.status' "${artifact_dir}/health/client-server-before.json")"
backend_initial_status="$(jq -r '.status' "${artifact_dir}/health/backend-server-before.json")"
test "$(jq -r '."OS-EXT-SRV-ATTR:host"' "${artifact_dir}/health/client-server-before.json")" = node1
test "$(jq -r '."OS-EXT-SRV-ATTR:host"' "${artifact_dir}/health/backend-server-before.json")" = ading2
client_port_id="$(jq -r '.[0].ID' "${artifact_dir}/health/client-ports-before.json")"
backend_port_id="$(jq -r '.[0].ID' "${artifact_dir}/health/backend-ports-before.json")"
client_mac="$(jq -r '.[0]."MAC Address"' "${artifact_dir}/health/client-ports-before.json" | tr '[:upper:]' '[:lower:]')"
backend_mac="$(jq -r '.[0]."MAC Address"' "${artifact_dir}/health/backend-ports-before.json" | tr '[:upper:]' '[:lower:]')"
client_tap="tap${client_port_id:0:11}"
backend_tap="tap${backend_port_id:0:11}"

{
  remote node1 "systemctl is-active ${adapter_unit} || true"
  remote node1 "sudo bpftool net show || true"
  remote node1 "systemctl show -p ActiveState,SubState,MainPID ${adapter_unit} || true"
} >"${artifact_dir}/health/attachments-before.txt"
if remote node1 "systemctl is-active --quiet ${adapter_unit}"; then
  adapter_was_active=true
  remote node1 "sudo systemctl stop ${adapter_unit}"
fi

if [[ "${backend_initial_status}" == SHUTOFF ]]; then
  openstack_cli server start "${backend_server}"
  backend_started_by_run=true
  wait_server_status "${backend_server}" ACTIVE
elif [[ "${backend_initial_status}" != ACTIVE ]]; then
  echo "backend VM must be ACTIVE or SHUTOFF, got ${backend_initial_status}" >&2
  exit 1
fi
if [[ "${client_initial_status}" == SHUTOFF ]]; then
  openstack_cli server start "${client_server}"
  client_started_by_run=true
  wait_server_status "${client_server}" ACTIVE
elif [[ "${client_initial_status}" != ACTIVE ]]; then
  echo "client VM must be ACTIVE or SHUTOFF, got ${client_initial_status}" >&2
  exit 1
fi

wait_guest_agent node1 "${client_instance}"
wait_guest_agent node2 "${backend_instance}"
wait_tap_binding node1 "${client_tap}" "${client_port_id}" "${client_mac}"
wait_tap_binding node2 "${backend_tap}" "${backend_port_id}" "${backend_mac}"

remote node1 "mkdir -p ${node1_run}"
remote node2 "mkdir -p ${node2_run}"
copy_to_host "${qga_exec_local}" node1 /tmp/linux-accel-qga-exec.sh
copy_to_host "${qga_copy_local}" node1 /tmp/linux-accel-qga-copy-to.sh
copy_to_host "${qga_exec_local}" node2 /tmp/linux-accel-qga-exec.sh
copy_to_host "${qga_copy_local}" node2 /tmp/linux-accel-qga-copy-to.sh
remote node1 'chmod 0755 /tmp/linux-accel-qga-exec.sh /tmp/linux-accel-qga-copy-to.sh'
remote node2 'chmod 0755 /tmp/linux-accel-qga-exec.sh /tmp/linux-accel-qga-copy-to.sh'

for path in \
  "${offline_deb_dir}/memcached_1.6.40-1ubuntu0.1_amd64.deb" \
  "${offline_deb_dir}/libevent-2.1-7t64_2.1.12-stable-10build2_amd64.deb" \
  "${offline_deb_dir}/liblua5.4-0_5.4.8-1build1_amd64.deb"; do
  test -s "${path}"
  copy_to_host "${path}" node2 "${node2_run}/$(basename "${path}")"
done
remote node2 \
  "cd ${node2_run}; printf '%s  %s\n' 3872214a9bc723123c1a78831c99f20416a5fa758ae1ebc682fd9af438759195 memcached_1.6.40-1ubuntu0.1_amd64.deb 8c14223ae11b2bba96afa0a1a08206cc63ad220d999e90a119f7c76549c62e16 libevent-2.1-7t64_2.1.12-stable-10build2_amd64.deb ff589ea3f181b89dd76b0240f79c59ac2f13f24e2053f624f774f596c7ef7897 liblua5.4-0_5.4.8-1build1_amd64.deb | sha256sum -c -" \
  >"${artifact_dir}/health/backend-deb-sha256.txt"

client_guest "mkdir -p ${guest_run}"
backend_guest "mkdir -p ${guest_run}"
copy_to_guest node1 "${client_instance}" "${linux_dir}/memcached_udp_zipf_bench" \
  "${guest_run}/memcached_udp_zipf_bench" 0755
copy_to_guest node2 "${backend_instance}" "${linux_dir}/memcached_udp_zipf_bench" \
  "${guest_run}/memcached_udp_zipf_bench" 0755
for deb in memcached_1.6.40-1ubuntu0.1_amd64.deb \
  libevent-2.1-7t64_2.1.12-stable-10build2_amd64.deb \
  liblua5.4-0_5.4.8-1build1_amd64.deb; do
  copy_to_guest node2 "${backend_instance}" "${node2_run}/${deb}" \
    "${guest_run}/${deb}" 0644
done

backend_guest \
  "set -e; mkdir -p ${guest_run}/root; for deb in ${guest_run}/*.deb; do dpkg-deb -x \"\${deb}\" ${guest_run}/root; done; LD_LIBRARY_PATH=${guest_run}/root/usr/lib/x86_64-linux-gnu ldd ${guest_run}/root/usr/bin/memcached" \
  >"${artifact_dir}/health/backend-runtime.txt"
backend_guest \
  "set -e; test ! -e /run/systemd/system/${backend_unit}; systemd-run --unit=${backend_unit} --collect --property=Type=simple --setenv=LD_LIBRARY_PATH=${guest_run}/root/usr/lib/x86_64-linux-gnu -- ${guest_run}/root/usr/bin/memcached -u root -l ${backend_ip} -p ${server_port} -U ${server_port} -t 2 -m 128" \
  >"${artifact_dir}/health/backend-start.txt"
backend_service_started=true
backend_guest \
  "for i in \$(seq 1 50); do systemctl is-active --quiet ${backend_unit} && ss -lnut | awk '\$1==\"udp\" && \$5 ~ /:${server_port}\$/ {u=1} \$1==\"tcp\" && \$5 ~ /:${server_port}\$/ {t=1} END{exit !(u&&t)}' && exit 0; sleep 0.1; done; journalctl --no-pager -o cat -u ${backend_unit}; exit 1" \
  >"${artifact_dir}/health/backend-ready.txt"

backend_guest \
  "${guest_run}/memcached_udp_zipf_bench --server ${backend_ip}:${server_port} --population ${population} --hot-keys ${hot_keys} --zipf ${zipf} --populate" \
  >"${artifact_dir}/logs/populate.log"
client_guest "ping -c 2 -W 1 ${backend_ip}" \
  >"${artifact_dir}/health/client-backend-ping.txt"
client_guest "$(client_command) --threads 1 --requests 8 --warmup 0 --seed 1" \
  >"${artifact_dir}/health/client-memcached-smoke.log"
grep -q 'failed=0' "${artifact_dir}/health/client-memcached-smoke.log"

remote node1 \
  "${linux_dir}/memcached_udp_zipf_bench --server ${backend_ip}:${server_port} --population ${population} --hot-keys ${hot_keys} --zipf ${zipf} --emit-policy ${client_tap} >${node1_run}/linux-accel-policy.conf; test \$(wc -l <${node1_run}/linux-accel-policy.conf) -eq ${hot_keys}"
remote node1 "cp ${node1_run}/linux-accel-policy.conf ${node1_run}/policy-copy.conf"
remote node1 "cat ${node1_run}/policy-copy.conf" >"${artifact_dir}/linux-accel-policy.conf"

for mode in nohook bmc linux-accel; do
  correctness "${mode}"
done

for repetition in $(seq 1 "${repetitions}"); do
  case "$(( (repetition - 1) % 3 ))" in
    0) modes=(nohook bmc linux-accel) ;;
    1) modes=(linux-accel bmc nohook) ;;
    2) modes=(bmc nohook linux-accel) ;;
  esac
  for mode in "${modes[@]}"; do
    run_case "${mode}" "${repetition}"
  done
done

cleanup_loader
stop_backend_service
restore_environment

capture_openstack_status "${artifact_dir}/health/openstack-after.txt"
capture_kubernetes "${artifact_dir}/health/kubernetes-after.txt"
cmp -s "${artifact_dir}/health/kubernetes-before.txt" \
  "${artifact_dir}/health/kubernetes-after.txt"
openstack_capture "${artifact_dir}/health/client-server-after.json" \
  server show "${client_server}" -f json
openstack_capture "${artifact_dir}/health/backend-server-after.json" \
  server show "${backend_server}" -f json
test "$(jq -r '.status' "${artifact_dir}/health/client-server-after.json")" = "${client_initial_status}"
test "$(jq -r '.status' "${artifact_dir}/health/backend-server-after.json")" = "${backend_initial_status}"
if ${adapter_was_active}; then
  remote node1 "systemctl is-active --quiet ${adapter_unit}"
fi
{
  remote node1 "systemctl is-active ${adapter_unit} || true"
  remote node1 "sudo bpftool net show || true"
} >"${artifact_dir}/health/attachments-after.txt"

{
  echo "profile=openstack-tap-mixed"
  echo "competitor=Orange-OpenSource/bmc-cache@2997145508e02c55aa92f63a0009ac2a26800810+audited-modern-kernel-port"
  echo "topology=client VM -> client TAP generic XDP -> OVS/OVN/Geneve -> backend VM Memcached"
  echo "client_server=${client_server}"
  echo "client_instance=${client_instance}"
  echo "client_port=${client_port_id}"
  echo "client_tap=${client_tap}"
  echo "backend_server=${backend_server}"
  echo "backend_instance=${backend_instance}"
  echo "backend_port=${backend_port_id}"
  echo "backend_tap=${backend_tap}"
  echo "key_distribution=finite Zipf(${zipf})"
  echo "key_bytes=16"
  echo "value_bytes=32"
  echo "scaled_population=${population}"
  echo "scaled_hot_keys=${hot_keys}"
  echo "scaled_equal_active_cache_entries=${hot_keys}"
  echo "threads=${threads}"
  echo "requests_per_thread=${requests_per_thread}"
  echo "warmup_per_thread=${warmup}"
  echo "repetitions=${repetitions}"
  echo "client_initial_status=${client_initial_status}"
  echo "backend_initial_status=${backend_initial_status}"
  remote node1 "uname -a"
  remote node2 "uname -a"
  remote node1 "sha256sum ${bmc_dir}/bmc_loader ${bmc_dir}/bmc_kern.o ${linux_dir}/udp_fastpath ${linux_dir}/udp_fastpath.bpf.o ${linux_dir}/memcached_udp_zipf_bench"
} >"${artifact_dir}/metadata.txt"

python3 "${repo_root}/tools/analyze_bmc_competitor_bench.py" \
  --output-dir "${artifact_dir}/analysis" "${artifact_dir}"

trap - EXIT INT TERM
cat "${artifact_dir}/analysis/summary.md"
