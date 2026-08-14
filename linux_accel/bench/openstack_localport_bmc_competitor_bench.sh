#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_dir="${1:?usage: $0 ARTIFACT_DIR [smoke|formal]}"
profile="${2:-formal}"

ssh_key="${SSH_KEY:-/Users/tankaiwen/vnet-dataplane/openstack-deployment/config/deploy_key}"
node1_target="${NODE1_SSH:-ading@10.115.24.245}"
node2_target="${NODE2_SSH:-ading2@10.115.24.114}"
node3_target="${NODE3_SSH:-ading3@10.115.24.40}"
release_root="${RELEASE_ROOT:-/opt/competitor-bench/releases/competitor-preflight-20260813-173626}"
bmc_dir="${BMC_DIR:-${release_root}/bmc-modern-v14}"
linux_dir="${LINUX_DIR:-${release_root}/linux-accel-bmc-target-v8}"
client_instance="${CLIENT_INSTANCE:-instance-00000012}"
client_tap="${CLIENT_TAP:-tapaa5e3ccb-96}"
client_port="${CLIENT_PORT:-aa5e3ccb-96d7-4960-8d02-2d5dda7e0eed}"
client_mac="${CLIENT_MAC:-fa:16:3e:93:10:92}"
client_iface="${CLIENT_IFACE:-ens3}"
backend_ns="${BACKEND_NS:-ovnmeta-2644af16-f4f0-4f46-9950-8faff490f187}"
backend_ip="${BACKEND_IP:-192.168.110.1}"
server_port="${SERVER_PORT:-11211}"
population="${POPULATION:-16384}"
hot_keys="${HOT_KEYS:-4096}"
cache_entries="${CACHE_ENTRIES:-4096}"
zipf="${ZIPF:-0.99}"
timed_timeout_ms="${TIMED_TIMEOUT_MS:-50}"
max_failure_pct="${MAX_FAILURE_PCT:-0.01}"
path_profile="${PATH_PROFILE:-mixed}"

case "${path_profile}" in
  mixed)
    query_population="${population}"
    query_hot_keys="${hot_keys}"
    query_cache_entries="${cache_entries}"
    query_key_offset=0
    query_expect_miss=false
    ;;
  all-hit)
    query_population=1
    query_hot_keys=1
    query_cache_entries=1
    query_key_offset=0
    query_expect_miss=false
    ;;
  all-miss)
    query_population="${population}"
    query_hot_keys=0
    query_cache_entries=0
    query_key_offset="${population}"
    query_expect_miss=true
    ;;
  *)
    echo "PATH_PROFILE must be mixed, all-hit, or all-miss" >&2
    exit 2
    ;;
esac

case "${profile}" in
  smoke)
    repetitions="${REPETITIONS:-1}"
    threads="${THREADS:-1}"
    requests_per_thread="${REQUESTS_PER_THREAD:-1000}"
    warmup="${WARMUP:-100}"
    ;;
  formal)
    repetitions="${REPETITIONS:-6}"
    threads="${THREADS:-2}"
    requests_per_thread="${REQUESTS_PER_THREAD:-25000}"
    warmup="${WARMUP:-1000}"
    ;;
  *)
    echo "profile must be smoke or formal" >&2
    exit 2
    ;;
esac

run_name="$(basename "${artifact_dir}" | tr -cd 'A-Za-z0-9_.-')"
short_id="$(printf '%s' "${run_name}" | shasum -a 256 | cut -c1-10)"
backend_unit="linux-accel-oslp-backend-${short_id}.service"
guest_client="/run/linux-accel-memcached-${short_id}"
guest_probe="/run/linux-accel-memcached-probe-${short_id}.py"
remote_policy="/tmp/linux-accel-oslp-policy-${short_id}.conf"
loader_unit=""
loader_started=false
backend_started=false
restored=false

mkdir -p "${artifact_dir}"/{health,correctness,cases,logs,system,analysis}

shell_quote()
{
  printf '%q' "$1"
}

ssh_to()
{
  local target="$1"
  shift
  ssh -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    "${target}" "$@"
}

remote()
{
  ssh_to "${node2_target}" "$@"
}

guest()
{
  local command="$1"
  remote "/tmp/linux-accel-qga-exec.sh ${client_instance} $(shell_quote "${command}")"
}

copy_to_guest()
{
  local source="$1" destination="$2" mode="$3"
  remote "/tmp/linux-accel-qga-copy-to.sh ${client_instance} $(shell_quote "${source}") $(shell_quote "${destination}") ${mode}"
}

capture_kubernetes()
{
  local output="$1" target label
  : >"${output}"
  for target in "${node2_target}" "${node3_target}"; do
    if [[ "${target}" == "${node2_target}" ]]; then
      label=node2
    else
      label=node3
    fi
    ssh_to "${target}" \
      'for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
      | sed "s/^/${label} /" >>"${output}"
  done
  if grep -q '=active$' "${output}"; then
    echo "Kubernetes must remain stopped" >&2
    return 1
  fi
}

capture_node1_reachability()
{
  local output="$1"
  if ssh -i "${ssh_key}" -o BatchMode=yes -o ConnectTimeout=3 \
      -o StrictHostKeyChecking=accept-new "${node1_target}" 'hostname; uptime' \
      >"${output}" 2>&1; then
    printf '%s\n' reachable >>"${output}"
  else
    printf '%s\n' unreachable >>"${output}"
  fi
}

capture_openstack_health()
{
  local output="$1"
  {
    printf 'captured_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    for endpoint in \
      http://10.115.24.250/auth/login/ \
      http://10.115.24.250:5000/v3 \
      http://10.115.24.250:9292/ \
      http://10.115.24.250:8774/ \
      http://10.115.24.250:8780/ \
      http://10.115.24.250:9696/healthcheck; do
      code="$(curl -sS -o /dev/null --connect-timeout 3 --max-time 5 -w '%{http_code}' "${endpoint}" || true)"
      printf '%s %s\n' "${endpoint}" "${code:-000}"
    done
  } >"${output}"
  remote \
    'for unit in openvswitch-switch ovs-vswitchd ovn-controller libvirtd nova-compute neutron-ovn-metadata-agent mariadb rabbitmq-server haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done; printf "ovn_controller=%s\n" "$(sudo ovn-appctl -t ovn-controller connection-status 2>/dev/null || true)"' \
    >"${output}.node2-units"
  ssh_to "${node3_target}" \
    'for unit in openvswitch-switch ovs-vswitchd ovn-controller libvirtd nova-compute neutron-ovn-metadata-agent mariadb rabbitmq-server haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done; printf "ovn_controller=%s\n" "$(sudo ovn-appctl -t ovn-controller connection-status 2>/dev/null || true)"' \
    >"${output}.node3-units"
}

capture_attachments()
{
  local output="$1"
  {
    remote "sudo bpftool net show dev ${client_tap} || true"
    remote "sudo tc qdisc show dev ${client_tap} || true"
    remote "sudo tc filter show dev ${client_tap} ingress || true"
    remote "sudo tc filter show dev ${client_tap} egress || true"
  } >"${output}" 2>&1
}

memcached_counter()
{
  local name="$1"
  remote \
    "sudo ip netns exec ${backend_ns} ${linux_dir}/memcached_udp_zipf_bench --server ${backend_ip}:${server_port} --population ${population} --hot-keys ${hot_keys} --cache-entries ${cache_entries} --zipf ${zipf} --stats" \
    | awk -v wanted="${name}" '$1=="STAT" && $2==wanted {gsub(/\r/,"",$3); print $3; exit}'
}

tap_packets()
{
  local direction="$1"
  remote "ip -s link show dev ${client_tap}" \
    | awk -v wanted="${direction}:" '$1==wanted {getline; print $2; exit}'
}

metric_from_log()
{
  local path="$1" name="$2"
  awk -v wanted="${name}" \
    '{for (i=1; i<=NF; i++) {split($i, value, "="); if (value[1]==wanted) {print value[2]; exit}}}' \
    "${path}"
}

cleanup_loader()
{
  local log_path="${1:-}"
  if ${loader_started} && [[ -n "${loader_unit}" ]]; then
    remote "sudo systemctl stop ${loader_unit}" >/dev/null 2>&1 || true
    if [[ -n "${log_path}" ]]; then
      remote "sudo journalctl --no-pager -o cat -u ${loader_unit}" \
        >"${log_path}" 2>&1 || true
    fi
    loader_started=false
    loader_unit=""
  fi
  # BMC removes its filter but leaves the clsact qdisc.  The preflight rejects
  # pre-existing owners, so this qdisc is benchmark-owned and safe to remove.
  remote "sudo tc qdisc del dev ${client_tap} clsact" >/dev/null 2>&1 || true
}

restore_environment()
{
  ${restored} && return 0
  set +e
  cleanup_loader "${artifact_dir}/logs/loader-cleanup.log"
  if ${backend_started}; then
    remote "sudo systemctl stop ${backend_unit}" >/dev/null 2>&1 || true
    remote "sudo journalctl --no-pager -o cat -u ${backend_unit}" \
      >"${artifact_dir}/logs/backend-service.log" 2>&1 || true
    backend_started=false
  fi
  guest "rm -f ${guest_client} ${guest_probe}" >/dev/null 2>&1 || true
  remote "rm -f ${remote_policy}" >/dev/null 2>&1 || true
  restored=true
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

wait_attachment()
{
  local need_tc="$1"
  for unused in $(seq 1 50); do
    if remote "sudo bpftool net show dev ${client_tap}" 2>/dev/null | grep -q 'generic id'; then
      if [[ "${need_tc}" == 0 ]] || \
         remote "sudo tc filter show dev ${client_tap} egress" 2>/dev/null | grep -q 'bmc_tx_filter'; then
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
  if remote "sudo bpftool net show dev ${client_tap}" 2>/dev/null | grep -Eq '(generic|native|offload) id'; then
    echo "unexpected XDP owner on ${client_tap}" >&2
    return 1
  fi
  case "${mode}" in
    nohook)
      ;;
    bmc)
      loader_unit="linux-accel-oslp-bmc-${short_id}-${label}.service"
      remote \
        "sudo systemd-run --unit=${loader_unit} --collect --property=Type=simple ${bmc_dir}/bmc_loader --dev ${client_tap} --bpf-object ${bmc_dir}/bmc_kern.o --xdp-mode generic" \
        >"${artifact_dir}/logs/${label}-start.log"
      loader_started=true
      wait_attachment 1
      ;;
    linux-accel)
      loader_unit="linux-accel-oslp-udp-${short_id}-${label}.service"
      remote \
        "sudo systemd-run --unit=${loader_unit} --collect --property=Type=simple ${linux_dir}/udp_fastpath --policy-file ${remote_policy} --bpf-object ${linux_dir}/udp_fastpath.bpf.o --xdp-mode generic" \
        >"${artifact_dir}/logs/${label}-start.log"
      loader_started=true
      wait_attachment 0
      ;;
    *)
      return 2
      ;;
  esac
  capture_attachments "${artifact_dir}/logs/${label}-attachments.txt"
}

cache_client_base()
{
  printf '%s' \
    "${guest_client} --server ${backend_ip}:${server_port} --population ${population} --hot-keys ${hot_keys} --cache-entries ${cache_entries} --zipf ${zipf}"
}

query_client_base()
{
  printf '%s' \
    "${guest_client} --server ${backend_ip}:${server_port} --population ${query_population} --hot-keys ${query_hot_keys} --key-offset ${query_key_offset} --zipf ${zipf}"
  if (( query_cache_entries > 0 )); then
    printf ' --cache-entries %s' "${query_cache_entries}"
  fi
  if ${query_expect_miss}; then
    printf ' --expect-miss'
  fi
}

warm_bmc()
{
  local label="$1" before after
  before="$(memcached_counter cmd_get)"
  guest "$(cache_client_base) --warm-all" >"${artifact_dir}/logs/${label}-bmc-warm.log"
  after="$(memcached_counter cmd_get)"
  test "$((after - before))" -eq "${cache_entries}"
}

correctness()
{
  local mode="$1" label="correctness-${mode}" before after delta
  set_mode "${mode}" "${label}"
  if [[ "${mode}" == bmc ]]; then
    warm_bmc "${label}"
  fi

  before="$(memcached_counter cmd_get)"
  guest \
    "${guest_client} --server ${backend_ip}:${server_port} --threads 1 --requests 64 --warmup 0 --population 1 --hot-keys 1 --cache-entries 1 --timeout-ms 200 --seed 42" \
    >"${artifact_dir}/correctness/${mode}-all-hit.log"
  after="$(memcached_counter cmd_get)"
  delta=$((after - before))
  grep -q 'failed=0' "${artifact_dir}/correctness/${mode}-all-hit.log"
  if [[ "${mode}" == nohook ]]; then
    test "${delta}" -eq 64
  else
    test "${delta}" -eq 0
  fi
  printf 'mode=%s path=all-hit backend_delta=%s\n' "${mode}" "${delta}" \
    >"${artifact_dir}/correctness/${mode}-all-hit-backend.txt"

  before="$(memcached_counter cmd_get)"
  guest \
    "${guest_client} --server ${backend_ip}:${server_port} --threads 1 --requests 64 --warmup 0 --population 64 --hot-keys 0 --key-offset ${population} --expect-miss --timeout-ms 200 --seed 43" \
    >"${artifact_dir}/correctness/${mode}-all-miss.log"
  after="$(memcached_counter cmd_get)"
  delta=$((after - before))
  grep -q 'failed=0' "${artifact_dir}/correctness/${mode}-all-miss.log"
  test "${delta}" -eq 64
  printf 'mode=%s path=all-miss backend_delta=%s\n' "${mode}" "${delta}" \
    >"${artifact_dir}/correctness/${mode}-all-miss-backend.txt"

  if [[ "${mode}" != nohook ]]; then
    before="$(memcached_counter cmd_get)"
    guest \
      "${guest_probe} --server ${backend_ip}:${server_port} --key 0 --request-id 0 --timeout-ms 500" \
      >"${artifact_dir}/correctness/${mode}-packet-probe.json"
    after="$(memcached_counter cmd_get)"
    test "$((after - before))" -eq 0
  fi
  cleanup_loader "${artifact_dir}/logs/${label}-loader.log"
}

run_case()
{
  local mode="$1" repetition="$2" label="${mode}-r${repetition}"
  local case_dir="${artifact_dir}/cases/${label}"
  local before_cmd after_cmd before_rx after_rx before_tx after_tx
  local client_rc attempted failed
  mkdir -p "${case_dir}"
  set_mode "${mode}" "${label}"
  if [[ "${mode}" == bmc ]]; then
    warm_bmc "${label}"
  fi
  guest \
    "$(query_client_base) --threads ${threads} --requests ${warmup} --warmup 0 --seed 77" \
    >"${artifact_dir}/logs/${label}-warmup.log"

  before_cmd="$(memcached_counter cmd_get)"
  before_rx="$(tap_packets RX)"
  before_tx="$(tap_packets TX)"
  printf '%s\n' "${before_cmd}" >"${case_dir}/backend-before.txt"
  remote 'cat /proc/stat' >"${case_dir}/proc-stat-before.txt"
  remote 'cat /proc/softirqs' >"${case_dir}/softirqs-before.txt"
  remote 'cat /proc/net/softnet_stat' >"${case_dir}/softnet-before.txt"
  remote 'cat /proc/net/snmp' >"${case_dir}/snmp-before.txt"
  guest 'cat /proc/stat' >"${case_dir}/guest-proc-stat-before.txt"
  guest 'cat /proc/net/snmp' >"${case_dir}/guest-snmp-before.txt"
  guest 'cat /proc/net/netstat' >"${case_dir}/guest-netstat-before.txt"
  guest "ip -s link show dev ${client_iface}" >"${case_dir}/guest-link-before.txt"
  guest "ethtool -S ${client_iface} 2>/dev/null || true" \
    >"${case_dir}/guest-ethtool-before.txt"
  remote "ip -s link show dev ${client_tap}" >"${case_dir}/client-tap-before.txt"

  set +e
  guest \
    "$(query_client_base) --threads ${threads} --requests ${requests_per_thread} --warmup 0 --timeout-ms ${timed_timeout_ms} --seed 202108" \
    >"${case_dir}/client.log"
  client_rc=$?
  set -e

  after_cmd="$(memcached_counter cmd_get)"
  after_rx="$(tap_packets RX)"
  after_tx="$(tap_packets TX)"
  printf '%s\n' "${after_cmd}" >"${case_dir}/backend-after.txt"
  remote 'cat /proc/stat' >"${case_dir}/proc-stat-after.txt"
  remote 'cat /proc/softirqs' >"${case_dir}/softirqs-after.txt"
  remote 'cat /proc/net/softnet_stat' >"${case_dir}/softnet-after.txt"
  remote 'cat /proc/net/snmp' >"${case_dir}/snmp-after.txt"
  guest 'cat /proc/stat' >"${case_dir}/guest-proc-stat-after.txt"
  guest 'cat /proc/net/snmp' >"${case_dir}/guest-snmp-after.txt"
  guest 'cat /proc/net/netstat' >"${case_dir}/guest-netstat-after.txt"
  guest "ip -s link show dev ${client_iface}" >"${case_dir}/guest-link-after.txt"
  guest "ethtool -S ${client_iface} 2>/dev/null || true" \
    >"${case_dir}/guest-ethtool-after.txt"
  remote "ip -s link show dev ${client_tap}" >"${case_dir}/client-tap-after.txt"
  attempted="$(metric_from_log "${case_dir}/client.log" attempted)"
  failed="$(metric_from_log "${case_dir}/client.log" failed)"
  test -n "${attempted}"
  test -n "${failed}"
  printf 'mode=%s repetition=%s backend_delta=%s client_tap_rx_delta=%s client_tap_tx_delta=%s client_rc=%s\n' \
    "${mode}" "${repetition}" "$((after_cmd - before_cmd))" \
    "$((after_rx - before_rx))" "$((after_tx - before_tx))" "${client_rc}" \
    >"${case_dir}/metadata.txt"
  if ! awk -v failed="${failed}" -v attempted="${attempted}" \
      -v maximum="${max_failure_pct}" \
      'BEGIN {exit !(attempted > 0 && (100.0 * failed / attempted) <= maximum)}'; then
    echo "${label}: failure rate exceeds ${max_failure_pct}%" >&2
    return 1
  fi
  cleanup_loader "${case_dir}/loader.log"
}

test -r "${ssh_key}"
test -x "${repo_root}/tools/openstack_qga_exec.sh"
test -x "${repo_root}/tools/openstack_qga_copy_to.sh"
test -r "${repo_root}/bench/memcached_udp_probe.py"
for path in "${bmc_dir}/bmc_loader" "${bmc_dir}/bmc_kern.o" \
  "${bmc_dir}/BUILD-METADATA.txt" \
  "${linux_dir}/udp_fastpath" "${linux_dir}/udp_fastpath.bpf.o" \
  "${linux_dir}/memcached_udp_zipf_bench"; do
  remote "test -s ${path}"
done

bmc_profile_cache_entries="$(
  remote \
    "awk -F= '\$1 == \"profile_cache_entries\" {print \$2; exit}' ${bmc_dir}/BUILD-METADATA.txt"
)"
if [[ ! "${bmc_profile_cache_entries}" =~ ^[0-9]+$ ]]; then
  echo "cannot determine BMC cache capacity from BUILD-METADATA.txt" >&2
  exit 2
fi
if [[ "${path_profile}" == mixed ]] &&
   [[ "${bmc_profile_cache_entries}" -ne "${cache_entries}" ]]; then
  echo "mixed profile cache-capacity mismatch: BMC=${bmc_profile_cache_entries}, linux_accel=${cache_entries}" >&2
  exit 2
fi

capture_kubernetes "${artifact_dir}/health/kubernetes-before.txt"
capture_node1_reachability "${artifact_dir}/health/node1-before.txt"
capture_openstack_health "${artifact_dir}/health/openstack-before.txt"
remote "sudo virsh domstate ${client_instance}; sudo virsh domuuid ${client_instance}; sudo virsh dumpxml ${client_instance} | sha256sum" \
  >"${artifact_dir}/health/client-vm-before.txt"
remote "test \"\$(sudo virsh domstate ${client_instance} | tr -d '\\r')\" = running"
remote "sudo virsh qemu-agent-command ${client_instance} '{\"execute\":\"guest-ping\"}'" \
  >"${artifact_dir}/health/qga-before.json"
remote "test -e /sys/class/net/${client_tap}"
guest "test -e /sys/class/net/${client_iface}"
test "$(remote "sudo ovs-vsctl --if-exists get Interface ${client_tap} external_ids:iface-id | tr -d '\"[:space:]'")" = "${client_port}"
test "$(remote "sudo ovs-vsctl --if-exists get Interface ${client_tap} external_ids:attached-mac | tr -d '\"[:space:]' | tr '[:upper:]' '[:lower:]'")" = "${client_mac}"
test "$(remote "sudo ovs-vsctl port-to-br ${client_tap}")" = br-int
remote "sudo ip netns list | grep -q '^${backend_ns} '"
remote "sudo ip netns exec ${backend_ns} ip -4 address show | grep -q '${backend_ip}/24'"
remote 'test "$(systemctl is-active openvswitch-switch)" = active; test "$(systemctl is-active ovn-controller)" = active; test "$(systemctl is-active libvirtd)" = active; test "$(sudo ovn-appctl -t ovn-controller connection-status)" = connected'

capture_attachments "${artifact_dir}/health/attachments-before.txt"
if grep -Eq '(generic|native|offload) id|clsact/(ingress|egress)|qdisc clsact' \
    "${artifact_dir}/health/attachments-before.txt"; then
  echo "client TAP already has an XDP/tc owner" >&2
  exit 1
fi

scp -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "${repo_root}/tools/openstack_qga_exec.sh" \
  "${node2_target}:/tmp/linux-accel-qga-exec.sh"
scp -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "${repo_root}/tools/openstack_qga_copy_to.sh" \
  "${node2_target}:/tmp/linux-accel-qga-copy-to.sh"
scp -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "${repo_root}/bench/memcached_udp_probe.py" \
  "${node2_target}:/tmp/linux-accel-memcached-probe-${short_id}.py"
remote 'chmod 0755 /tmp/linux-accel-qga-exec.sh /tmp/linux-accel-qga-copy-to.sh'
copy_to_guest "${linux_dir}/memcached_udp_zipf_bench" "${guest_client}" 0755
copy_to_guest "/tmp/linux-accel-memcached-probe-${short_id}.py" "${guest_probe}" 0755

remote \
  "sudo systemd-run --unit=${backend_unit} --collect --property=Type=simple /usr/sbin/ip netns exec ${backend_ns} /usr/bin/memcached -u root -l ${backend_ip} -p ${server_port} -U ${server_port} -t 2 -m 128" \
  >"${artifact_dir}/health/backend-start.txt"
backend_started=true
for unused in $(seq 1 50); do
  if remote "sudo ip netns exec ${backend_ns} ss -lnut" | grep -q ":${server_port} "; then
    break
  fi
  sleep 0.1
done
remote "sudo ip netns exec ${backend_ns} ss -lnut | grep -q ':${server_port} '"

guest \
  "${guest_client} --server ${backend_ip}:${server_port} --population ${population} --hot-keys ${hot_keys} --cache-entries ${cache_entries} --zipf ${zipf} --populate" \
  >"${artifact_dir}/logs/populate.log"
guest "ping -c 2 -W 1 ${backend_ip}" >"${artifact_dir}/health/client-backend-ping.txt"
guest \
  "${guest_client} --server ${backend_ip}:${server_port} --threads 1 --requests 8 --warmup 0 --population 8 --hot-keys 8 --cache-entries 8 --timeout-ms 200" \
  >"${artifact_dir}/health/client-memcached-smoke.log"
grep -q 'failed=0' "${artifact_dir}/health/client-memcached-smoke.log"

remote \
  "${linux_dir}/memcached_udp_zipf_bench --server ${backend_ip}:${server_port} --population ${population} --hot-keys ${hot_keys} --cache-entries ${cache_entries} --zipf ${zipf} --emit-policy ${client_tap} >${remote_policy}; test \$(wc -l <${remote_policy}) -eq ${cache_entries}"
remote "cat ${remote_policy}" >"${artifact_dir}/linux-accel-policy.conf"

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

restore_environment
capture_kubernetes "${artifact_dir}/health/kubernetes-after.txt"
cmp -s "${artifact_dir}/health/kubernetes-before.txt" \
  "${artifact_dir}/health/kubernetes-after.txt"
capture_node1_reachability "${artifact_dir}/health/node1-after.txt"
capture_openstack_health "${artifact_dir}/health/openstack-after.txt"
remote "sudo virsh domstate ${client_instance}; sudo virsh domuuid ${client_instance}; sudo virsh dumpxml ${client_instance} | sha256sum" \
  >"${artifact_dir}/health/client-vm-after.txt"
cmp -s "${artifact_dir}/health/client-vm-before.txt" \
  "${artifact_dir}/health/client-vm-after.txt"
capture_attachments "${artifact_dir}/health/attachments-after.txt"
if grep -Eq '(generic|native|offload) id|clsact/(ingress|egress)|qdisc clsact' \
    "${artifact_dir}/health/attachments-after.txt"; then
  echo "benchmark left an attachment behind" >&2
  exit 1
fi

{
  echo "profile=openstack-localport-tap-${path_profile}"
  echo "competitor=Orange-OpenSource/bmc-cache@2997145508e02c55aa92f63a0009ac2a26800810+linux7-verifier+tap-tailroom-compat"
  echo "topology=OpenStack VM ens3 -> host TAP generic XDP -> OVS br-int/OVN -> existing OVN localport namespace -> Memcached"
  echo "scope=same-compute OpenStack TAP/OVS/OVN fallback; no Geneve and no cross-compute hop"
  echo "client_instance=${client_instance}"
  echo "client_port=${client_port}"
  echo "client_tap=${client_tap}"
  echo "client_iface=${client_iface}"
  echo "backend_namespace=${backend_ns}"
  echo "backend_ip=${backend_ip}"
  echo "key_distribution=finite Zipf(${zipf})"
  echo "key_bytes=16"
  echo "value_bytes=32"
  echo "population=${population}"
  echo "hot_keys=${hot_keys}"
  echo "cache_entries=${cache_entries}"
  echo "bmc_profile_cache_entries=${bmc_profile_cache_entries}"
  echo "path_profile=${path_profile}"
  echo "query_population=${query_population}"
  echo "query_hot_keys=${query_hot_keys}"
  echo "query_cache_entries=${query_cache_entries}"
  echo "query_key_offset=${query_key_offset}"
  echo "query_expect_miss=${query_expect_miss}"
  echo "threads=${threads}"
  echo "requests_per_thread=${requests_per_thread}"
  echo "warmup_per_thread=${warmup}"
  echo "timed_timeout_ms=${timed_timeout_ms}"
  echo "maximum_allowed_failure_pct=${max_failure_pct}"
  echo "repetitions=${repetitions}"
  echo "kubernetes=stopped"
  echo "openstack_api_dependency=none"
  remote "uname -a"
  remote "sha256sum ${bmc_dir}/bmc_kern.c ${bmc_dir}/bmc_kern.o ${bmc_dir}/bmc_loader ${linux_dir}/udp_fastpath.bpf.o ${linux_dir}/udp_fastpath ${linux_dir}/memcached_udp_zipf_bench"
} >"${artifact_dir}/metadata.txt"

python3 "${repo_root}/tools/analyze_bmc_competitor_bench.py" \
  --allow-failures --output-dir "${artifact_dir}/analysis" "${artifact_dir}"

trap - EXIT INT TERM
cat "${artifact_dir}/analysis/summary.md"
