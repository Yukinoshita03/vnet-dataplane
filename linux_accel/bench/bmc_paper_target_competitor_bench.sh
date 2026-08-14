#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
default_linux_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd)"
release_root="${RELEASE_ROOT:-/opt/competitor-bench/releases/competitor-preflight-20260813-173626}"
bmc_dir="${BMC_DIR:-${release_root}/bmc-modern-v10}"
linux_dir="${LINUX_DIR:-${default_linux_dir}}"
out_dir="${OUT_DIR:-/opt/competitor-bench/results/bmc-paper-target-$(date +%Y%m%d-%H%M%S)}"
repetitions="${REPETITIONS:-3}"
threads="${THREADS:-8}"
requests_per_thread="${REQUESTS_PER_THREAD:-25000}"
warmup="${WARMUP:-1000}"
client_cpus="${CLIENT_CPUS:-0-5}"
loader_cpu="${LOADER_CPU:-6}"
server_cpus="${SERVER_CPUS:-8-11}"
population="${POPULATION:-4096}"
hot_keys="${HOT_KEYS:-1024}"
cache_entries="${CACHE_ENTRIES:-${hot_keys}}"
zipf="${ZIPF:-0.99}"
distribution="${DISTRIBUTION:-zipf}"
workload_profile="${WORKLOAD_PROFILE:-bmc-paper-parameters-scaled}"
source_profile="${SOURCE_PROFILE:-BMC-NSDI21-Zipf-0.99}"
path_profile="${PATH_PROFILE:-mixed}"
query_population="${QUERY_POPULATION:-}"
query_hot_keys="${QUERY_HOT_KEYS:-}"
query_key_offset="${QUERY_KEY_OFFSET:-}"
query_expect_miss="${QUERY_EXPECT_MISS:-}"
server_ip="198.19.0.3"
server_port="11211"
tag="$(( $$ % 90000 + 10000 ))"
client_ns="bmc-c-${tag}"
server_ns="bmc-s-${tag}"
client_host="bmch${tag}"
client_peer="bmcp${tag}"
server_host="bmsh${tag}"
server_peer="bmsp${tag}"
bridge="bmcb${tag}"
memcached_pid=""
loader_pid=""

mkdir -p "${out_dir}"/{health,correctness,cases,logs,system}

cleanup_loader()
{
  if [[ -n "${loader_pid}" ]]; then
    kill -TERM "${loader_pid}" >/dev/null 2>&1 || true
    wait "${loader_pid}" >/dev/null 2>&1 || true
    loader_pid=""
  fi
}

cleanup()
{
  set +e
  cleanup_loader
  if [[ -n "${memcached_pid}" ]]; then
    kill -TERM "${memcached_pid}" >/dev/null 2>&1 || true
    wait "${memcached_pid}" >/dev/null 2>&1 || true
  fi
  ip netns del "${client_ns}" >/dev/null 2>&1 || true
  ip netns del "${server_ns}" >/dev/null 2>&1 || true
  ip link del dev "${bridge}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for path in "${bmc_dir}/bmc_loader" "${bmc_dir}/bmc_kern.o" \
  "${linux_dir}/udp_fastpath" "${linux_dir}/udp_fastpath.bpf.o" \
  "${linux_dir}/memcached_udp_zipf_bench"; do
  test -s "${path}"
done
for command in ip tc bpftool memcached jq taskset; do
  command -v "${command}" >/dev/null
done
if (( EUID != 0 )); then
  echo "run as root" >&2
  exit 1
fi

case "${path_profile}" in
  mixed)
    query_population="${query_population:-${population}}"
    query_hot_keys="${query_hot_keys:-${hot_keys}}"
    query_key_offset="${query_key_offset:-0}"
    query_expect_miss="${query_expect_miss:-0}"
    ;;
  all-hit)
    query_population="${query_population:-1}"
    query_hot_keys="${query_hot_keys:-1}"
    query_key_offset="${query_key_offset:-0}"
    query_expect_miss="${query_expect_miss:-0}"
    ;;
  all-miss)
    query_population="${query_population:-${population}}"
    query_hot_keys="${query_hot_keys:-0}"
    query_key_offset="${query_key_offset:-${population}}"
    query_expect_miss="${query_expect_miss:-1}"
    ;;
  *)
    echo "PATH_PROFILE must be mixed, all-hit, or all-miss" >&2
    exit 2
    ;;
esac
if [[ ! "${query_population}" =~ ^[1-9][0-9]*$ ||
      ! "${query_hot_keys}" =~ ^[0-9]+$ ||
      ! "${query_key_offset}" =~ ^[0-9]+$ ||
      ! "${query_expect_miss}" =~ ^[01]$ ]]; then
  echo "invalid query profile parameters" >&2
  exit 2
fi
if (( query_hot_keys > query_population )); then
  echo "QUERY_HOT_KEYS exceeds QUERY_POPULATION" >&2
  exit 2
fi
if [[ ! "${population}" =~ ^[1-9][0-9]*$ ||
      ! "${hot_keys}" =~ ^[0-9]+$ ||
      ! "${cache_entries}" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid population/cache parameters" >&2
  exit 2
fi
if (( hot_keys > population || cache_entries > population || cache_entries > 4096 )); then
  echo "HOT_KEYS/CACHE_ENTRIES exceed workload or BMC map capacity" >&2
  exit 2
fi
if [[ "${distribution}" != zipf && "${distribution}" != facebook-etc-coarse ]]; then
  echo "DISTRIBUTION must be zipf or facebook-etc-coarse" >&2
  exit 2
fi
if [[ "${distribution}" == facebook-etc-coarse ]] &&
   (( hot_keys == 0 || hot_keys >= population )); then
  echo "facebook-etc-coarse requires 0 < HOT_KEYS < POPULATION" >&2
  exit 2
fi
timed_requests=$((threads * requests_per_thread))
facebook_cold_keys=$((population - hot_keys))

for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
  printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done >"${out_dir}/health/kubernetes-before.txt"
if grep -q '=active$' "${out_dir}/health/kubernetes-before.txt"; then
  echo "Kubernetes must stay stopped" >&2
  exit 1
fi

ip netns add "${client_ns}"
ip netns add "${server_ns}"
ip link add "${client_host}" type veth peer name "${client_peer}"
ip link add "${server_host}" type veth peer name "${server_peer}"
ip link set "${client_peer}" netns "${client_ns}"
ip link set "${server_peer}" netns "${server_ns}"
ip link add "${bridge}" type bridge
ip link set "${bridge}" up
ip link set "${client_host}" master "${bridge}"
ip link set "${server_host}" master "${bridge}"
ip link set "${client_host}" up
ip link set "${server_host}" up
ip netns exec "${client_ns}" ip link set lo up
ip netns exec "${server_ns}" ip link set lo up
ip netns exec "${client_ns}" ip link set "${client_peer}" address 02:19:00:00:00:02
ip netns exec "${server_ns}" ip link set "${server_peer}" address 02:19:00:00:00:03
ip netns exec "${client_ns}" ip address add 198.19.0.2/24 dev "${client_peer}"
ip netns exec "${server_ns}" ip address add "${server_ip}/24" dev "${server_peer}"
ip netns exec "${client_ns}" ip link set "${client_peer}" up
ip netns exec "${server_ns}" ip link set "${server_peer}" up

ip netns exec "${server_ns}" taskset -c "${server_cpus}" memcached -u root -l "${server_ip}" \
  -p "${server_port}" -U "${server_port}" -t 8 -m 128 \
  >"${out_dir}/logs/memcached.log" 2>&1 &
memcached_pid=$!
for unused in $(seq 1 50); do
  if ip netns exec "${server_ns}" ss -lnut | grep -q ":${server_port} "; then
    break
  fi
  sleep 0.1
done
ip netns exec "${server_ns}" ss -lnut | grep -q ":${server_port} "

client=(ip netns exec "${client_ns}" taskset -c "${client_cpus}" "${linux_dir}/memcached_udp_zipf_bench" --server "${server_ip}:${server_port}" --population "${population}" --hot-keys "${hot_keys}" --cache-entries "${cache_entries}" --distribution "${distribution}" --zipf "${zipf}")
query_distribution="${distribution}"
if [[ "${path_profile}" != mixed ]]; then
  query_distribution=zipf
fi
query_client=(ip netns exec "${client_ns}" taskset -c "${client_cpus}" "${linux_dir}/memcached_udp_zipf_bench" --server "${server_ip}:${server_port}" --population "${query_population}" --hot-keys "${query_hot_keys}" --key-offset "${query_key_offset}" --distribution "${query_distribution}" --zipf "${zipf}")
if [[ "${path_profile}" == mixed ]]; then
  query_client+=(--cache-entries "${cache_entries}")
elif [[ "${path_profile}" == all-hit ]]; then
  query_client+=(--cache-entries 1)
fi
if [[ "${query_expect_miss}" == 1 ]]; then
  query_client+=(--expect-miss)
fi
server_control=(ip netns exec "${server_ns}" "${linux_dir}/memcached_udp_zipf_bench" --server "${server_ip}:${server_port}" --population "${population}" --hot-keys "${hot_keys}" --zipf "${zipf}")
"${client[@]}" --populate >"${out_dir}/logs/populate.log"
"${server_control[@]}" --stats >"${out_dir}/logs/memcached-stats-after-populate.txt"
"${client[@]}" --emit-policy "${client_host}" >"${out_dir}/linux-accel-policy.conf"
test "$(wc -l < "${out_dir}/linux-accel-policy.conf")" -eq "${cache_entries}"

server_rx_packets()
{
  ip netns exec "${server_ns}" ip -s link show dev "${server_peer}" | \
    awk '/RX:/{getline; print $2; exit}'
}

memcached_counter()
{
  local name="$1"
  "${server_control[@]}" --stats | awk -v wanted="${name}" '$1=="STAT" && $2==wanted {gsub(/\r/,"",$3); print $3; exit}'
}

wait_xdp()
{
  for unused in $(seq 1 50); do
    if bpftool net show dev "${client_host}" 2>/dev/null | grep -q 'generic id'; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

set_mode()
{
  local mode="$1"
  cleanup_loader
  if bpftool net show dev "${client_host}" 2>/dev/null | grep -Eq '(generic|native|offload) id'; then
    echo "unexpected XDP owner remains on ${client_host}" >&2
    exit 1
  fi
  case "${mode}" in
    nohook)
      ;;
    bmc)
      printf '\nstart=%s\n' "$(date -Is)" >>"${out_dir}/logs/bmc-loader.log"
      taskset -c "${loader_cpu}" "${bmc_dir}/bmc_loader" --dev "${client_host}" \
        --bpf-object "${bmc_dir}/bmc_kern.o" --xdp-mode generic \
        >>"${out_dir}/logs/bmc-loader.log" 2>&1 &
      loader_pid=$!
      wait_xdp
      ;;
    linux-accel)
      printf '\nstart=%s\n' "$(date -Is)" >>"${out_dir}/logs/linux-accel-loader.log"
      taskset -c "${loader_cpu}" "${linux_dir}/udp_fastpath" \
        --policy-file "${out_dir}/linux-accel-policy.conf" \
        --bpf-object "${linux_dir}/udp_fastpath.bpf.o" --xdp-mode generic \
        >>"${out_dir}/logs/linux-accel-loader.log" 2>&1 &
      loader_pid=$!
      wait_xdp
      ;;
    *)
      return 2
      ;;
  esac
  local attachment_file
  attachment_file="${out_dir}/logs/${mode}-attachment-$(date +%s%N).txt"
  bpftool net show dev "${client_host}" >"${attachment_file}" 2>&1 || true
  tc filter show dev "${client_host}" egress >>"${attachment_file}" 2>&1 || true
}

bmc_invalidation_correctness()
{
  local before before_update after_update before_get after_get
  set_mode bmc
  warm_bmc
  before="$(memcached_counter cmd_set)"
  "${client[@]}" --update-key 0 >"${out_dir}/correctness/bmc-update-key.log"
  before_update="${before}"
  after_update="$(memcached_counter cmd_set)"
  test "$((after_update - before_update))" -eq 1
  before_get="$(memcached_counter cmd_get)"
  "${client[@]}" --threads 1 --requests 1 --warmup 0 --population 1 \
    --hot-keys 1 --cache-entries 1 --distribution zipf --seed 1 \
    >"${out_dir}/correctness/bmc-after-set-get.log"
  after_get="$(memcached_counter cmd_get)"
  test "$((after_get - before_get))" -eq 1
  cleanup_loader
  tail -n 1 "${out_dir}/logs/bmc-loader.log" \
    >"${out_dir}/correctness/bmc-invalidation-stats.txt"
  grep -Eq 'invalidation=[1-9][0-9]*' \
    "${out_dir}/correctness/bmc-invalidation-stats.txt"
}

warm_bmc()
{
  local before after
  before="$(memcached_counter cmd_get)"
  "${client[@]}" --warm-all >"${out_dir}/logs/bmc-warm.log"
  sleep 0.2
  after="$(memcached_counter cmd_get)"
  test "$((after - before))" -eq "${cache_entries}"
}

correctness()
{
  local mode="$1" before after delta expected
  set_mode "${mode}"
  if [[ "${mode}" == bmc ]]; then
    warm_bmc
  elif [[ "${mode}" == nohook ]]; then
    "${client[@]}" --warm-all >"${out_dir}/logs/nohook-warm.log"
  fi
  before="$(memcached_counter cmd_get)"
  "${query_client[@]}" --threads 1 --requests 64 --warmup 0 --seed 42 \
    >"${out_dir}/correctness/${mode}.log"
  after="$(memcached_counter cmd_get)"
  delta=$((after - before))
  if [[ "${mode}" == nohook || "${query_expect_miss}" == 1 ]]; then
    expected=64
  elif [[ "${path_profile}" == all-hit ]]; then
    expected=0
  else
    expected=-1
  fi
  if [[ "${expected}" -ge 0 ]]; then
    test "${delta}" -eq "${expected}"
  else
    test "${delta}" -gt 0
    test "${delta}" -lt 64
  fi
  printf 'mode=%s backend_delta=%s expected=%s\n' "${mode}" "${delta}" "${expected}" \
    >"${out_dir}/correctness/${mode}-backend.txt"
}

run_case()
{
  local mode="$1" repetition="$2" case_dir before_cmd after_cmd before_rx after_rx
  case_dir="${out_dir}/cases/${mode}-r${repetition}"
  mkdir -p "${case_dir}"
  set_mode "${mode}"
  if [[ "${mode}" == bmc ]]; then
    warm_bmc
  elif [[ "${mode}" == nohook ]]; then
    "${client[@]}" --warm-all >"${out_dir}/logs/nohook-warm.log"
  fi
  "${query_client[@]}" --threads "${threads}" --requests "${warmup}" --warmup 0 --seed 77 \
    >/dev/null
  before_cmd="$(memcached_counter cmd_get)"
  before_rx="$(server_rx_packets)"
  printf '%s\n' "${before_cmd}" >"${case_dir}/backend-before.txt"
  printf '%s\n' "${before_rx}" >"${case_dir}/server-rx-before.txt"
  cat /proc/stat >"${case_dir}/proc-stat-before.txt"
  cat /proc/softirqs >"${case_dir}/softirqs-before.txt"
  cat /proc/net/softnet_stat >"${case_dir}/softnet-before.txt"
  cat /proc/net/snmp >"${case_dir}/snmp-before.txt"
  ip netns exec "${client_ns}" cat /proc/net/snmp \
    >"${case_dir}/client-snmp-before.txt"
  ip netns exec "${client_ns}" cat /proc/net/netstat \
    >"${case_dir}/client-netstat-before.txt"
  "${query_client[@]}" --threads "${threads}" --requests "${requests_per_thread}" \
    --warmup 0 --seed 202108 >"${case_dir}/client.log"
  after_cmd="$(memcached_counter cmd_get)"
  after_rx="$(server_rx_packets)"
  printf '%s\n' "${after_cmd}" >"${case_dir}/backend-after.txt"
  printf '%s\n' "${after_rx}" >"${case_dir}/server-rx-after.txt"
  cat /proc/stat >"${case_dir}/proc-stat-after.txt"
  cat /proc/softirqs >"${case_dir}/softirqs-after.txt"
  cat /proc/net/softnet_stat >"${case_dir}/softnet-after.txt"
  cat /proc/net/snmp >"${case_dir}/snmp-after.txt"
  ip netns exec "${client_ns}" cat /proc/net/snmp \
    >"${case_dir}/client-snmp-after.txt"
  ip netns exec "${client_ns}" cat /proc/net/netstat \
    >"${case_dir}/client-netstat-after.txt"
  awk -v mode="${mode}" -v rep="${repetition}" \
    -v backend="$((after_cmd - before_cmd))" -v rx="$((after_rx - before_rx))" \
    'BEGIN{printf "mode=%s repetition=%d backend_delta=%d server_rx_delta=%d\n", mode,rep,backend,rx}' \
    >"${case_dir}/metadata.txt"
  grep -q 'failed=0' "${case_dir}/client.log"
  if [[ "${distribution}" == facebook-etc-coarse ]] &&
     (( timed_requests % 100 == 0 )); then
    grep -q ' hot_fraction=0.99 ' "${case_dir}/client.log"
  fi
}

for mode in nohook bmc linux-accel; do
  correctness "${mode}"
done
bmc_invalidation_correctness

for repetition in $(seq 1 "${repetitions}"); do
  order_index=$(( (repetition - 1) % 6 + 1 ))
  case "${order_index}" in
    1) modes=(nohook bmc linux-accel) ;;
    2) modes=(linux-accel bmc nohook) ;;
    3) modes=(bmc nohook linux-accel) ;;
    4) modes=(nohook linux-accel bmc) ;;
    5) modes=(linux-accel nohook bmc) ;;
    6) modes=(bmc linux-accel nohook) ;;
  esac
  for mode in "${modes[@]}"; do
    run_case "${mode}" "${repetition}"
  done
done

cleanup_loader
for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
  printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done >"${out_dir}/health/kubernetes-after.txt"
cmp -s "${out_dir}/health/kubernetes-before.txt" "${out_dir}/health/kubernetes-after.txt"

{
  echo "profile=${workload_profile}"
  echo "competitor=Orange-OpenSource/bmc-cache@2997145508e02c55aa92f63a0009ac2a26800810+linux7-verifier+tap-tailroom+ipv4-checksum-compat"
  echo "topology=netns+veth+bridge generic XDP on client-side host veth"
  echo "source_profile=${source_profile}"
  echo "key_distribution=${distribution}"
  echo "zipf_exponent=${zipf}"
  echo "key_bytes=16"
  echo "value_bytes=32"
  echo "paper_population=100000000"
  echo "scaled_population=${population}"
  echo "paper_bmc_to_memcached_memory_allocation_ratio=25%"
  echo "paper_memory_ratio_reproduced=false"
  echo "paper_ratio_note=25% is a memory-allocation ratio, not a cached-key ratio"
  echo "traffic_hot_keys=${hot_keys}"
  echo "nominal_cache_entries_per_xdp_path=${cache_entries}"
  echo "bmc_compile_time_max_entries=4096"
  echo "cache_entry_comparison=same nominal entry count; byte footprint differs by implementation"
  echo "path_profile=${path_profile}"
  echo "query_population=${query_population}"
  echo "query_hot_keys=${query_hot_keys}"
  echo "query_key_offset=${query_key_offset}"
  echo "query_expect_miss=${query_expect_miss}"
  echo "threads=${threads}"
  echo "requests_per_thread=${requests_per_thread}"
  echo "timed_requests_per_case=${timed_requests}"
  echo "warmup_per_thread=${warmup}"
  echo "repetitions=${repetitions}"
  echo "mode_order=balanced-six-permutation-cycle"
  echo "client_cpus=${client_cpus}"
  echo "loader_cpu=${loader_cpu}"
  echo "server_cpus=${server_cpus}"
  echo "bmc_dir=${bmc_dir}"
  echo "linux_dir=${linux_dir}"
  if [[ "${distribution}" == facebook-etc-coarse ]]; then
    echo "facebook_observed_constraint=approximately 50% distinct keys carry 99% requests; other 50% carry 1%"
    echo "facebook_hot_half_sampling=synthetic uniform; source publishes no within-half rank CDF"
    echo "facebook_cold_half_sampling=deterministic without replacement until wrap"
    echo "facebook_cold_half_keys=${facebook_cold_keys}"
    echo "facebook_exact_trace_scale=$([[ "${timed_requests}" -eq $((100 * facebook_cold_keys)) ]] && echo true || echo false)"
  fi
  uname -a
  sha256sum "${bmc_dir}/bmc_kern.c" "${bmc_dir}/bmc_kern.o" \
    "${bmc_dir}/bmc_loader" "${linux_dir}/udp_fastpath.bpf.o" \
    "${linux_dir}/udp_fastpath" "${linux_dir}/memcached_udp_zipf_bench"
} >"${out_dir}/metadata.txt"

echo "artifacts=${out_dir}"
