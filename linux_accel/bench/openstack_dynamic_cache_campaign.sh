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

host_client_pin="/sys/fs/bpf/vnet-dynamic-client"
host_grpc_pin="/sys/fs/bpf/vnet-dynamic-grpc-monitor"
guest_server_pin="/sys/fs/bpf/vnet-dynamic-server"
guest_grpc_pin="/sys/fs/bpf/vnet-dynamic-grpc"
sudo_askpass="/tmp/vnet-dynamic-askpass-$$"

dns_client_pid=""
grpc_monitor_pid=""
dynamic_in_fd=""
dynamic_out_fd=""
dynamic_pid=""

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
  local encoded
  encoded="$(printf '%s' "${command}" | base64 | tr -d '\n')"
  sudo_cmd ip netns exec "${netns}" ssh "${ssh_opts[@]}" \
    "${guest_user}@${ip}" "echo ${encoded} | base64 -d | bash"
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

stop_host_process() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  sudo_cmd kill -TERM "${pid}" >/dev/null 2>&1 || true
  for _ in {1..50}; do
    sudo_cmd kill -0 "${pid}" >/dev/null 2>&1 || return 0
    sleep 0.05
  done
  sudo_cmd kill -KILL "${pid}" >/dev/null 2>&1 || true
}

stop_monitors() {
  stop_host_process "${grpc_monitor_pid}"
  stop_host_process "${dns_client_pid}"
  grpc_monitor_pid=""
  dns_client_pid=""
  guest_cmd "${backend_ip}" \
    'if [ -s /tmp/vnet-dynamic-dns-monitor.pid ]; then
       pid="$(cat /tmp/vnet-dynamic-dns-monitor.pid)"
       sudo -n kill -TERM "$pid" 2>/dev/null || true
       for i in $(seq 1 20); do
         sudo -n kill -0 "$pid" 2>/dev/null || break
         sleep 0.05
       done
       sudo -n kill -KILL "$pid" 2>/dev/null || true
     fi
     sleep 0.2
     sudo -n ip link set dev ens3 xdp off 2>/dev/null || true
     sudo -n tc qdisc del dev ens3 clsact 2>/dev/null || true
     rm -f /tmp/vnet-dynamic-dns-monitor.pid' >/dev/null 2>&1 || true
  sudo_cmd ip link set dev "${client_tap}" xdp off >/dev/null 2>&1 || true
  sudo_cmd tc filter del dev "${client_tap}" ingress pref 1 handle 1 bpf \
    >/dev/null 2>&1 || true
  sudo_cmd tc filter del dev "${client_tap}" egress pref 1 handle 1 bpf \
    >/dev/null 2>&1 || true
  sudo_cmd tc filter del dev "${client_tap}" ingress pref 1 handle 2 bpf \
    >/dev/null 2>&1 || true
  sudo_cmd tc filter del dev "${client_tap}" egress pref 1 handle 2 bpf \
    >/dev/null 2>&1 || true
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
  trap - EXIT
  set +e
  stop_dynamic_controller
  stop_monitors
  sudo_cmd rm -rf -- "${host_client_pin}" "${host_grpc_pin}"
  guest_cmd "${client_ip}" \
    'sudo -n killall -q openstack_dns_harness openstack_grpc_harness 2>/dev/null || true
     rm -f /tmp/openstack_dns_harness /tmp/openstack_grpc_harness'
  guest_cmd "${backend_ip}" \
    'sudo -n killall -q openstack_dns_harness openstack_grpc_harness grpc_fast_cache dns_monitor 2>/dev/null || true
     sudo -n ip link set dev ens3 xdp off 2>/dev/null || true
     sudo -n tc qdisc del dev ens3 clsact 2>/dev/null || true
     sudo -n rm -rf -- /sys/fs/bpf/vnet-dynamic-server /sys/fs/bpf/vnet-dynamic-grpc
     rm -f /tmp/openstack_dns_harness /tmp/openstack_grpc_harness
     rm -f /tmp/grpc_fast_cache /tmp/cachectl /tmp/dns_monitor
     rm -f /tmp/dns_xdp_monitor.bpf.o /tmp/dynamic_cache_controller
     rm -f /tmp/dns_cache_stats_reader /tmp/vnet-dynamic-*.txt
     rm -f /tmp/vnet-dynamic-*.log /tmp/vnet-dynamic-*.pid'
  {
    echo "host_runtime_pins:"
    sudo_cmd find /sys/fs/bpf -maxdepth 1 -type d \
      \( -name 'vnet-dynamic-client' -o -name 'vnet-dynamic-grpc-monitor' \) \
      -print
    echo "host_test_processes:"
    ps -eo pid,args |
      grep -E 'vnet-dynamic|dns_monitor|grpc_monitor' |
      grep -v grep || true
    echo "host_tc_ingress:"
    sudo_cmd tc filter show dev "${client_tap}" ingress || true
    echo "host_tc_egress:"
    sudo_cmd tc filter show dev "${client_tap}" egress || true
    echo "guest_residue:"
    guest_cmd "${backend_ip}" \
      "ps -ef | grep -E 'openstack_(dns|grpc)_harness|grpc_fast_cache|dns_monitor' | grep -v grep || true
       sudo -n find /sys/fs/bpf -maxdepth 1 -type d -name 'vnet-dynamic-*' -print"
  } >"${out_dir}/cleanup-audit.txt" 2>&1
  rm -f "${sudo_askpass}"
  printf 'cleanup_status=%s\n' "${status}" >"${out_dir}/cleanup-status.txt"
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
} >"${out_dir}/environment.txt"
openstack server list --long >"${out_dir}/openstack-servers.txt" 2>&1 || true
openstack port list >"${out_dir}/openstack-ports.txt" 2>&1 || true
sudo_cmd ovs-vsctl show >"${out_dir}/ovs-topology.txt" 2>&1 || true
sudo_cmd ip -details link show "${client_tap}" \
  >"${out_dir}/client-interface.txt" 2>&1

copy_guest "${client_ip}" "${dns_harness}" /tmp/openstack_dns_harness
copy_guest "${client_ip}" "${grpc_harness}" /tmp/openstack_grpc_harness
copy_guest "${backend_ip}" "${dns_harness}" /tmp/openstack_dns_harness
copy_guest "${backend_ip}" "${grpc_harness}" /tmp/openstack_grpc_harness
copy_guest "${backend_ip}" "${grpc_cache}" /tmp/grpc_fast_cache
copy_guest "${backend_ip}" "${cachectl}" /tmp/cachectl
copy_guest "${backend_ip}" "${dns_monitor}" /tmp/dns_monitor
copy_guest "${backend_ip}" "${dns_server_bpf}" /tmp/dns_xdp_monitor.bpf.o
copy_guest "${backend_ip}" "${controller}" /tmp/dynamic_cache_controller
copy_guest "${backend_ip}" "${stats_reader}" /tmp/dns_cache_stats_reader

server_cache_file="${out_dir}/server-cache.txt"
printf 'hot.%s %s 600\n' "${domain}" "${answer_ip}" >"${server_cache_file}"
printf 'shift-a.%s %s 600\n' "${domain}" "${answer_ip}" >>"${server_cache_file}"
printf 'shift-b.%s %s 600\n' "${domain}" "${answer_ip}" >>"${server_cache_file}"
for key in $(seq 0 7); do
  printf 'key-%s.%s %s 600\n' "${key}" "${domain}" "${answer_ip}" \
    >>"${server_cache_file}"
done
copy_guest "${backend_ip}" "${server_cache_file}" /tmp/vnet-dynamic-server-cache.txt

guest_cmd "${backend_ip}" \
  "sudo -n killall -q openstack_dns_harness openstack_grpc_harness grpc_fast_cache dns_monitor 2>/dev/null || true
   sudo -n mkdir -p /sys/fs/bpf
   mountpoint -q /sys/fs/bpf || sudo -n mount -t bpf bpf /sys/fs/bpf
   sudo -n rm -rf -- ${guest_server_pin} ${guest_grpc_pin}
   sudo -n mkdir -p ${guest_grpc_pin}
   printf '0\n' >/tmp/vnet-dynamic-dns-backend-count
   nohup sudo -n /tmp/openstack_dns_harness server 0.0.0.0 53 '${domain}' '${answer_ip}' 600 /tmp/vnet-dynamic-dns-backend-count >/tmp/vnet-dynamic-dns-backend.log 2>&1 </dev/null &
   nohup sudo -n /tmp/openstack_grpc_harness server '${backend_ip}' 50051 300 >/tmp/vnet-dynamic-grpc-backend.log 2>&1 </dev/null &
   sudo -n /tmp/openstack_grpc_harness seed ${guest_grpc_pin}/grpc_policy_map
   sudo -n /tmp/openstack_grpc_harness seed-response ${guest_grpc_pin}/grpc_response_cache '${grpc_payload}' SERVING 3600
   sudo -n bpftool map create ${guest_grpc_pin}/cache_runtime_control type array key 4 value 16 entries 1 name dyn_grpc_ctl
   cat >/tmp/vnet-dynamic-grpc-policy.txt <<EOF
grpc ${method} 3600 idempotent
grpc-cache ${method} ${grpc_payload} SERVING 3600
EOF
   sudo -n /tmp/cachectl --policy-file /tmp/vnet-dynamic-grpc-policy.txt --grpc-map ${guest_grpc_pin}/grpc_policy_map --grpc-response-map ${guest_grpc_pin}/grpc_response_cache --replace
   nohup sudo -n /tmp/grpc_fast_cache --grpc-map ${guest_grpc_pin}/grpc_policy_map --grpc-response-map ${guest_grpc_pin}/grpc_response_cache --runtime-control-map ${guest_grpc_pin}/cache_runtime_control --cache-role server --listen '${backend_ip}':50052 --backend '${backend_ip}':50051 --method '${method}' --verbose >/tmp/vnet-dynamic-grpc-cache.log 2>&1 </dev/null &"
sleep 1

guest_cmd "${backend_ip}" \
  "ps -ef | grep -E 'openstack_(dns|grpc)_harness|grpc_fast_cache' | grep -v grep
   ss -lunp | grep ':53 '
   ss -ltnp | grep -E ':5005[12] '" >"${out_dir}/service-state.txt"

start_monitors() {
  local label="$1"
  stop_monitors
  sudo_cmd rm -rf -- "${host_client_pin}" "${host_grpc_pin}"
  guest_cmd "${backend_ip}" \
    "sudo -n rm -rf -- ${guest_server_pin}
     setsid nohup sudo -n /tmp/dns_monitor --dev ens3 --hook xdp --role server --xdp-mode generic --bpf-object /tmp/dns_xdp_monitor.bpf.o --cache-file /tmp/vnet-dynamic-server-cache.txt --pin-dir ${guest_server_pin} > /tmp/vnet-dynamic-dns-monitor.log 2>&1 </dev/null & echo \$! >/tmp/vnet-dynamic-dns-monitor.pid"
  dns_client_pid="$(sudo_cmd bash -c \
    "setsid '${dns_monitor}' --dev '${client_tap}' --hook xdp --role client --xdp-mode generic --bpf-object '${dns_client_bpf}' --trusted-dns '${backend_ip}' --pin-dir '${host_client_pin}' >'${out_dir}/monitors/${label}.dns-client.log' 2>&1 </dev/null & echo \$!")"
  grpc_monitor_pid="$(sudo_cmd bash -c \
    "setsid '${grpc_monitor}' --dev '${client_tap}' --bpf-object '${grpc_bpf}' --port 50052 --pin-dir '${host_grpc_pin}' >'${out_dir}/monitors/${label}.grpc.log' 2>&1 </dev/null & echo \$!")"
  for _ in {1..80}; do
    if sudo_cmd test -e "${host_client_pin}/cache_runtime_control" &&
       guest_cmd "${backend_ip}" \
         "sudo -n test -e ${guest_server_pin}/cache_runtime_control"; then
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
  sudo_cmd "${controller}" \
    --control-map "${host_client_pin}/cache_runtime_control" \
    --initial-mode "${mode}" --initial-epoch "${epoch}" </dev/null \
    >"${out_dir}/decisions/${label}.host-publish.log"
  guest_cmd "${backend_ip}" \
    "sudo -n /tmp/dynamic_cache_controller --control-map ${guest_server_pin}/cache_runtime_control --control-map ${guest_grpc_pin}/cache_runtime_control --initial-mode '${mode}' --initial-epoch '${epoch}' </dev/null" \
    >"${out_dir}/decisions/${label}.guest-publish.log"
}

host_dns_stats() {
  sudo_cmd "${stats_reader}" "${host_client_pin}/dns_cache_stats"
}

guest_dns_stats() {
  guest_cmd "${backend_ip}" \
    "sudo -n /tmp/dns_cache_stats_reader ${guest_server_pin}/dns_cache_stats"
}

guest_grpc_stats() {
  guest_cmd "${backend_ip}" \
    "grep 'grpc_fast_cache listen=' /tmp/vnet-dynamic-grpc-cache.log | tail -n 1"
}

backend_count() {
  guest_cmd "${backend_ip}" \
    "tr -d '[:space:]' </tmp/vnet-dynamic-dns-backend-count"
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
  case "${workload}" in
    stable)
      guest_cmd "${client_ip}" \
        "/tmp/openstack_dns_harness client-workload '${backend_ip}' 53 '${domain}' '${answer_ip}' '${requests_per_window}' '${warmup}' stable 8" >"${output}"
      ;;
    burst)
      guest_cmd "${client_ip}" \
        "rm -f /tmp/vnet-dynamic-dns-burst-*.out
         for i in \$(seq 1 '${burst_clients}'); do
           /tmp/openstack_dns_harness client-workload '${backend_ip}' 53 '${domain}' '${answer_ip}' '$((requests_per_window / burst_clients))' '$((warmup / burst_clients))' hot 1 >/tmp/vnet-dynamic-dns-burst-\$i.out &
         done
         wait
         cat /tmp/vnet-dynamic-dns-burst-*.out" >"${output}"
      ;;
    hot-key)
      guest_cmd "${client_ip}" \
        "/tmp/openstack_dns_harness client-workload '${backend_ip}' 53 '${domain}' '${answer_ip}' '${requests_per_window}' '${warmup}' hot 1" >"${output}"
      ;;
    shifting-hot-key)
      guest_cmd "${client_ip}" \
        "/tmp/openstack_dns_harness client-workload '${backend_ip}' 53 '${domain}' '${answer_ip}' '${requests_per_window}' '${warmup}' shifting 2" >"${output}"
      ;;
    low-hit-rate)
      guest_cmd "${client_ip}" \
        "/tmp/openstack_dns_harness client-workload '${backend_ip}' 53 '${domain}' '${answer_ip}' '${requests_per_window}' '${warmup}' low-hit-rate '${requests_per_window}'" >"${output}"
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
  case "${workload}" in
    burst)
      guest_cmd "${client_ip}" \
        "rm -f /tmp/vnet-dynamic-grpc-burst-*.out
         for i in \$(seq 1 '${burst_clients}'); do
           /tmp/openstack_grpc_harness client '${backend_ip}' 50052 '$((requests_per_window / burst_clients))' '$((warmup / burst_clients))' '${grpc_payload}' >/tmp/vnet-dynamic-grpc-burst-\$i.out &
         done
         wait
         cat /tmp/vnet-dynamic-grpc-burst-*.out" >"${output}"
      ;;
    shifting-hot-key)
      guest_cmd "${client_ip}" \
        "/tmp/openstack_grpc_harness client '${backend_ip}' 50052 '$((requests_per_window / 2))' '$((warmup / 2))' '${grpc_payload}'
         /tmp/openstack_grpc_harness client '${backend_ip}' 50052 '$((requests_per_window / 2))' '$((warmup / 2))' '${grpc_shift_payload}'" >"${output}"
      ;;
    low-hit-rate)
      guest_cmd "${client_ip}" \
        "rm -f /tmp/vnet-dynamic-grpc-low-*.out
         for i in \$(seq 1 8); do
           /tmp/openstack_grpc_harness client '${backend_ip}' 50052 '$((requests_per_window / 8))' '$((warmup / 8))' \"unique-\$i\" >/tmp/vnet-dynamic-grpc-low-\$i.out &
         done
         wait
         cat /tmp/vnet-dynamic-grpc-low-*.out" >"${output}"
      ;;
    *)
      guest_cmd "${client_ip}" \
        "/tmp/openstack_grpc_harness client '${backend_ip}' 50052 '${requests_per_window}' '${warmup}' '${grpc_payload}'" >"${output}"
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

printf 'policy,workload,round,window,dns_success,dns_failed,dns_qps,dns_p95_us,grpc_success,grpc_failed,grpc_qps,grpc_p95_us,backend_requests,backend_qps,dns_hits,dns_misses,grpc_hits,grpc_misses,mode,epoch\n' \
  >"${out_dir}/windows.csv"
printf 'policy,workload,round,dns_success,dns_failed,dns_qps,grpc_success,grpc_failed,grpc_qps,backend_requests,max_dns_p95_us,max_grpc_p95_us,final_mode,final_epoch\n' \
  >"${out_dir}/runs.csv"

policies=(bypass server client dual dynamic)
workloads=(stable burst hot-key shifting-hot-key low-hit-rate)

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

      run_started="$(date +%s%N)"
      run_dns_success=0
      run_dns_failed=0
      run_grpc_success=0
      run_grpc_failed=0
      run_backend_start="$(backend_count)"
      max_dns_p95=0
      max_grpc_p95=0

      dns_stats_before="$(host_dns_stats)"
      grpc_stats_before="$(guest_grpc_stats)"
      run_grpc_fallback_start="$(field "${grpc_stats_before}" fallback)"
      for window in $(seq 1 "${windows}"); do
        raw_prefix="${out_dir}/raw/${label}-w${window}"
        backend_before="$(backend_count)"
        window_started="$(date +%s%N)"
        run_dns_load "${workload}" "${raw_prefix}.dns" &
        dns_job=$!
        run_grpc_load "${workload}" "${raw_prefix}.grpc" &
        grpc_job=$!
        wait "${dns_job}"
        wait "${grpc_job}"
        window_finished="$(date +%s%N)"
        backend_after="$(backend_count)"

        dns_result="$(aggregate_output "${raw_prefix}.dns" success)"
        grpc_result="$(aggregate_output "${raw_prefix}.grpc" count)"
        dns_success="$(field "${dns_result}" success)"
        dns_failed="$(field "${dns_result}" failed)"
        dns_p95="$(field "${dns_result}" p95_us)"
        grpc_success="$(field "${grpc_result}" success)"
        grpc_failed="$(field "${grpc_result}" failed)"
        grpc_p95="$(field "${grpc_result}" p95_us)"
        elapsed_ns=$((window_finished - window_started))
        dns_qps="$(awk -v count="${dns_success}" -v ns="${elapsed_ns}" \
          'BEGIN {printf "%.2f", count * 1000000000 / ns}')"
        grpc_qps="$(awk -v count="${grpc_success}" -v ns="${elapsed_ns}" \
          'BEGIN {printf "%.2f", count * 1000000000 / ns}')"
        backend_delta=$((backend_after - backend_before))

        dns_stats_after="$(host_dns_stats)"
        grpc_stats_after="$(guest_grpc_stats)"
        dns_hit_delta=$(( \
          $(delta_field "${dns_stats_after}" "${dns_stats_before}" cache_hit) + \
          $(delta_field "${dns_stats_after}" "${dns_stats_before}" shadow_hit) ))
        dns_miss_delta=$(( \
          $(delta_field "${dns_stats_after}" "${dns_stats_before}" cache_miss) + \
          $(delta_field "${dns_stats_after}" "${dns_stats_before}" shadow_miss) ))
        grpc_hit_delta="$(delta_field "${grpc_stats_after}" "${grpc_stats_before}" cache_hit)"
        grpc_miss_delta=$(( \
          $(delta_field "${grpc_stats_after}" "${grpc_stats_before}" policy_miss) + \
          $(delta_field "${grpc_stats_after}" "${grpc_stats_before}" policy_bypass) + \
          $(delta_field "${grpc_stats_after}" "${grpc_stats_before}" response_cache_miss) ))
        grpc_backend_delta="$(delta_field "${grpc_stats_after}" "${grpc_stats_before}" fallback)"
        grpc_runtime_error_delta="$(delta_field "${grpc_stats_after}" "${grpc_stats_before}" runtime_map_error)"
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
            current_mode="$(field "${decision}" mode)"
            current_epoch="$(field "${decision}" epoch)"
            apply_mode "${current_mode}" "${current_epoch}" \
              "${label}-w${window}"
          fi
        fi

        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
          "${policy}" "${workload}" "${round}" "${window}" \
          "${dns_success}" "${dns_failed}" "${dns_qps}" "${dns_p95}" \
          "${grpc_success}" "${grpc_failed}" "${grpc_qps}" "${grpc_p95}" \
          "${backend_requests}" "${backend_qps}" \
          "${dns_hit_delta}" "${dns_miss_delta}" \
          "${grpc_hit_delta}" "${grpc_miss_delta}" \
          "${current_mode}" "${current_epoch}" >>"${out_dir}/windows.csv"

        run_dns_success=$((run_dns_success + dns_success))
        run_dns_failed=$((run_dns_failed + dns_failed))
        run_grpc_success=$((run_grpc_success + grpc_success))
        run_grpc_failed=$((run_grpc_failed + grpc_failed))
        max_dns_p95="$(awk -v old="${max_dns_p95}" -v new="${dns_p95}" \
          'BEGIN {print new > old ? new : old}')"
        max_grpc_p95="$(awk -v old="${max_grpc_p95}" -v new="${grpc_p95}" \
          'BEGIN {print new > old ? new : old}')"
        dns_stats_before="${dns_stats_after}"
        grpc_stats_before="${grpc_stats_after}"
      done

      run_finished="$(date +%s%N)"
      run_elapsed=$((run_finished - run_started))
      run_backend_end="$(backend_count)"
      run_grpc_fallback_end="$(field "${grpc_stats_after}" fallback)"
      run_dns_qps="$(awk -v count="${run_dns_success}" -v ns="${run_elapsed}" \
        'BEGIN {printf "%.2f", count * 1000000000 / ns}')"
      run_grpc_qps="$(awk -v count="${run_grpc_success}" -v ns="${run_elapsed}" \
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
      stop_monitors
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
