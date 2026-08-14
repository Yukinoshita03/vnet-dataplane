#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
xpress_src="${XPRESS_SRC:?Set XPRESS_SRC to the xpress-dns source tree}"
build_dir="${BUILD_DIR:-${repo_dir}/build/radar-dns-xdp-competitor}"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/radar-dns-xdp-competitor/$(date +%Y%m%d-%H%M%S)}"
repetitions="${REPETITIONS:-3}"
rate="${RATE:-100000}"
duration="${DURATION:-5}"
threads="${THREADS:-6}"
batch="${BATCH:-32}"
timeout_us="${TIMEOUT_US:-50000}"
cpu_base="${CPU_BASE:-0}"
backend_cpu="${BACKEND_CPU:-8}"
control_cpu="${CONTROL_CPU:-6}"
seed="${SEED:-20260813}"
strict_validation="${STRICT_VALIDATION:-1}"
corpus_profile="${CORPUS_PROFILE:-radar-nl-observed}"
corpus_lines="${CORPUS_LINES:-50000}"
workload_profile="${WORKLOAD_PROFILE:-${corpus_profile}-rate-${rate}}"
source_profile="${SOURCE_PROFILE:-Cloudflare-Radar-NL-2026-08-13}"
warmup_duration="${WARMUP_DURATION:-1}"
client_tool="${CLIENT_TOOL:-burst}"
dnsperf_bin="${DNSPERF_BIN:-dnsperf}"
dnsperf_version="${DNSPERF_VERSION:-unknown}"
dnsperf_clients="${DNSPERF_CLIENTS:-8}"
dnsperf_threads="${DNSPERF_THREADS:-4}"
dnsperf_outstanding="${DNSPERF_OUTSTANDING:-20000}"
dnsperf_cpu_list="${DNSPERF_CPU_LIST:-0-7}"
run_resperf="${RUN_RESPERF:-0}"
resperf_bin="${RESPERF_BIN:-resperf}"
resperf_version="${RESPERF_VERSION:-${dnsperf_version}}"
resperf_repetitions="${RESPERF_REPETITIONS:-3}"
resperf_ramp="${RESPERF_RAMP:-15}"
resperf_max_qps="${RESPERF_MAX_QPS:-650000}"
resperf_clients="${RESPERF_CLIENTS:-8}"
resperf_outstanding="${RESPERF_OUTSTANDING:-65536}"
resperf_cpu_list="${RESPERF_CPU_LIST:-0-7}"

if [[ "$(uname -s)" != Linux || ${EUID} -ne 0 ]]; then
  echo "Run this benchmark as root on Linux" >&2
  exit 1
fi
for command in clang c++ gcc ip bpftool pkg-config python3 jq awk; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done
case "${client_tool}" in
  burst)
    ;;
  dnsperf)
    [[ -x "${dnsperf_bin}" ]] || {
      echo "dnsperf is not executable: ${dnsperf_bin}" >&2
      exit 1
    }
    ;;
  *)
    echo "CLIENT_TOOL must be burst or dnsperf" >&2
    exit 1
    ;;
esac
if [[ "${run_resperf}" -eq 1 && ! -x "${resperf_bin}" ]]; then
  echo "resperf is not executable: ${resperf_bin}" >&2
  exit 1
fi
[[ -f "${xpress_src}/src/xdp_dns_kern.c" ]] || {
  echo "XPRESS_SRC does not contain src/xdp_dns_kern.c" >&2
  exit 1
}

mkdir -p "${build_dir}" "${out_dir}"/{health,nohook,xpress,linux-accel,logs}
tag=$(( $$ % 100000 ))
client_ns="rdc${tag}"
server_ns="rds${tag}"
client_host="rdch${tag}"
client_peer="rdcp${tag}"
server_host="rdsh${tag}"
server_peer="rdsp${tag}"
bridge="rdb${tag}"
server_ip="198.20.0.3"
domain="radar.example.test"
backend_pid=""
loader_pid=""

cleanup()
{
  set +e
  [[ -z "${loader_pid}" ]] || kill -TERM "${loader_pid}" 2>/dev/null
  [[ -z "${backend_pid}" ]] || kill -TERM "${backend_pid}" 2>/dev/null
  [[ -z "${loader_pid}" ]] || wait "${loader_pid}" 2>/dev/null
  [[ -z "${backend_pid}" ]] || wait "${backend_pid}" 2>/dev/null
  ip netns del "${client_ns}" 2>/dev/null
  ip netns del "${server_ns}" 2>/dev/null
  ip link del dev "${bridge}" 2>/dev/null
}
trap cleanup EXIT INT TERM

multiarch_include="/usr/include/$(gcc -print-multiarch 2>/dev/null || true)"
bpf_includes=("-I${repo_dir}/src/include" "-I${repo_dir}/include")
[[ ! -d "${multiarch_include}" ]] || bpf_includes+=("-I${multiarch_include}")
clang -target bpf -O2 -g "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/dns_xdp_monitor.c" \
  -o "${build_dir}/dns_xdp_monitor.bpf.o"
clang -target bpf -O2 -g -I/usr/include/bpf \
  ${multiarch_include:+-I"${multiarch_include}"} -I"${xpress_src}/src" \
  -c "${xpress_src}/src/xdp_dns_kern.c" \
  -o "${build_dir}/xpress_dns.bpf.o"
read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
c++ -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  "${repo_dir}/bench/xpress_dns_loader.cpp" \
  -o "${build_dir}/xpress_dns_loader" "${libbpf_flags[@]}"
gcc -O2 -g -Wall -Wextra -Werror -pthread \
  "${repo_dir}/bench/physical_xdp_burst_client.c" \
  -o "${build_dir}/dns_burst_client"

python3 "${repo_dir}/tools/generate_openstack_dns_corpus.py" \
  --output "${out_dir}/queries.txt" \
  --manifest "${out_dir}/corpus-manifest.json" \
  --cache-output "${out_dir}/cache.txt" --domain "${domain}" \
  --lines "${corpus_lines}" --seed "${seed}" --profile "${corpus_profile}"
[[ "$(wc -l < "${out_dir}/queries.txt")" -eq "${corpus_lines}" ]]
[[ "$(wc -l < "${out_dir}/cache.txt")" -eq "$(jq -r .cache_entries "${out_dir}/corpus-manifest.json")" ]]

{
  echo "kernel=$(uname -r)"
  echo "libbpf=$(pkg-config --modversion libbpf)"
  echo "xpress_commit=${XPRESS_COMMIT:-unknown}"
  echo "profile=${workload_profile}"
  echo "corpus_profile=${corpus_profile}"
  echo "source_profile=${source_profile}"
  echo "radar_snapshot_date=2026-08-13"
  echo "repetitions=${repetitions}"
  echo "rate=${rate}"
  echo "duration=${duration}"
  echo "threads=${threads}"
  echo "batch=${batch}"
  echo "timeout_us=${timeout_us}"
  echo "client_cpu_range=${cpu_base}-$(( cpu_base + threads - 1 ))"
  echo "backend_cpu=${backend_cpu}"
  echo "control_cpu=${control_cpu}"
  echo "seed=${seed}"
  echo "strict_validation=${strict_validation}"
  echo "corpus_lines=${corpus_lines}"
  echo "warmup_duration=${warmup_duration}"
  echo "client_tool=${client_tool}"
  echo "dnsperf_version=${dnsperf_version}"
  echo "dnsperf_clients=${dnsperf_clients}"
  echo "dnsperf_threads=${dnsperf_threads}"
  echo "dnsperf_outstanding=${dnsperf_outstanding}"
  echo "dnsperf_cpu_list=${dnsperf_cpu_list}"
  echo "run_resperf=${run_resperf}"
  echo "resperf_version=${resperf_version}"
  echo "resperf_repetitions=${resperf_repetitions}"
  echo "resperf_ramp=${resperf_ramp}"
  echo "resperf_max_qps=${resperf_max_qps}"
  echo "resperf_clients=${resperf_clients}"
  echo "resperf_outstanding=${resperf_outstanding}"
  echo "resperf_cpu_list=${resperf_cpu_list}"
  echo "mode_order=balanced-six-permutation-cycle"
  echo "server_xdp_per_packet_telemetry=false"
  echo "corpus_sha256=$(sha256sum "${out_dir}/queries.txt" | awk '{print $1}')"
  echo "cache_sha256=$(sha256sum "${out_dir}/cache.txt" | awk '{print $1}')"
} >"${out_dir}/metadata.txt"
bpftool net show >"${out_dir}/health/attachments-before.txt"
for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
  printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done >"${out_dir}/health/kubernetes-before.txt"
if grep -q '=active$' "${out_dir}/health/kubernetes-before.txt"; then
  echo "Kubernetes must remain stopped" >&2
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
ip netns exec "${client_ns}" ip link set "${client_peer}" address 02:00:00:00:20:11
ip netns exec "${server_ns}" ip link set "${server_peer}" address 02:00:00:00:20:22
ip netns exec "${client_ns}" ip addr add 198.20.0.2/24 dev "${client_peer}"
ip netns exec "${server_ns}" ip addr add "${server_ip}/24" dev "${server_peer}"
ip netns exec "${client_ns}" ip link set "${client_peer}" up
ip netns exec "${server_ns}" ip link set "${server_peer}" up

ip netns exec "${server_ns}" python3 "${repo_dir}/bench/openstack_dns_backend.py" \
  --bind "${server_ip}" --port 53 --domain "${domain}" \
  --answer 10.0.0.123 --ttl 3600 \
  --count-file "${out_dir}/backend-count.json" \
  >"${out_dir}/backend.log" 2>&1 &
backend_pid=$!
taskset -cp "${backend_cpu}" "${backend_pid}" >"${out_dir}/backend-affinity.txt"
sleep 0.2
ip netns exec "${client_ns}" ping -c 1 -W 1 "${server_ip}" \
  >"${out_dir}/health/ping.txt"

backend_requests()
{
  kill -USR1 "${backend_pid}"
  sleep 0.15
  jq -r '.requests' "${out_dir}/backend-count.json"
}

metric()
{
  local file="$1" name="$2"
  awk -v name="${name}" '{for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]==name){print a[2];exit}}}' "${file}"
}

loader_stop()
{
  if [[ -z "${loader_pid}" ]]; then
    return 0
  fi
  kill -TERM "${loader_pid}"
  wait "${loader_pid}"
  loader_pid=""
  if bpftool net show dev "${client_host}" 2>/dev/null | grep -Eq '(generic|native|offload) id'; then
    echo "loader left an XDP attachment on ${client_host}" >&2
    exit 1
  fi
}

loader_start()
{
  local mode="$1"
  loader_stop
  case "${mode}" in
    nohook)
      ;;
    xpress)
      "${build_dir}/xpress_dns_loader" --dev "${client_host}" --xdp-mode generic \
        --bpf-object "${build_dir}/xpress_dns.bpf.o" \
        --cache-file "${out_dir}/cache.txt" \
        >>"${out_dir}/logs/xpress-loader.log" 2>&1 &
      loader_pid=$!
      ;;
    linux-accel)
      "${repo_dir}/build/dns_monitor" --dev "${client_host}" --hook xdp \
        --role server --xdp-mode generic \
        --bpf-object "${build_dir}/dns_xdp_monitor.bpf.o" \
        --cache-file "${out_dir}/cache.txt" \
        >>"${out_dir}/logs/linux-accel-loader.log" 2>&1 &
      loader_pid=$!
      ;;
    *)
      return 2
      ;;
  esac
  if [[ "${mode}" == nohook ]]; then
    return 0
  fi
  taskset -cp "${control_cpu}" "${loader_pid}" \
    >>"${out_dir}/${mode}/affinity.txt"
  for _ in $(seq 1 100); do
    if ip -details link show dev "${client_host}" | grep -q 'prog/xdp'; then
      return 0
    fi
    if ! kill -0 "${loader_pid}" 2>/dev/null; then
      tail -n 100 "${out_dir}/logs/${mode}-loader.log" >&2
      exit 1
    fi
    sleep 0.05
  done
  echo "${mode} XDP attach timed out" >&2
  exit 1
}

capture_system()
{
  local case_dir="$1" suffix="$2"
  cat /proc/stat >"${case_dir}/proc-stat-${suffix}.txt"
  cat /proc/softirqs >"${case_dir}/softirqs-${suffix}.txt"
  cat /proc/net/softnet_stat >"${case_dir}/softnet-${suffix}.txt"
  cat /proc/net/snmp >"${case_dir}/snmp-${suffix}.txt"
  ip -s link show dev "${client_host}" >"${case_dir}/client-link-${suffix}.txt"
  ip netns exec "${server_ns}" ip -s link show dev "${server_peer}" \
    >"${case_dir}/server-link-${suffix}.txt"
}

run_case()
{
  local mode="$1" repetition="$2"
  local before after case_dir
  case_dir="${out_dir}/${mode}/rep-${repetition}"
  mkdir -p "${case_dir}"
  loader_start "${mode}"

  # Warm sockets/code/cache lookup paths without contaminating timed counters.
  ip netns exec "${client_ns}" "${build_dir}/dns_burst_client" \
    --target "${server_ip}" --port 53 --rate "$((rate < 20000 ? rate : 20000))" \
    --duration "${warmup_duration}" --threads "${threads}" --batch "${batch}" \
    --timeout-us "${timeout_us}" --cpu-base "${cpu_base}" \
    --queries "${out_dir}/queries.txt" >"${case_dir}/warmup.log"
  grep -q 'invalid=0' "${case_dir}/warmup.log"

  before="$(backend_requests)"
  capture_system "${case_dir}" before
  case "${client_tool}" in
    burst)
      ip netns exec "${client_ns}" "${build_dir}/dns_burst_client" \
        --target "${server_ip}" --port 53 --rate "${rate}" \
        --duration "${duration}" --threads "${threads}" --batch "${batch}" \
        --timeout-us "${timeout_us}" --cpu-base "${cpu_base}" \
        --queries "${out_dir}/queries.txt" \
        | tee "${case_dir}/client.log"
      ;;
    dnsperf)
      LC_ALL=C ip netns exec "${client_ns}" taskset -c "${dnsperf_cpu_list}" \
        "${dnsperf_bin}" -s "${server_ip}" -p 53 \
        -d "${out_dir}/queries.txt" -l "${duration}" -Q "${rate}" \
        -q "${dnsperf_outstanding}" -T "${dnsperf_threads}" \
        -c "${dnsperf_clients}" -t 1 -S 1 \
        -O latency-histogram -O suppress=timeouts \
        >"${case_dir}/dnsperf.log" 2>&1
      python3 "${repo_dir}/tools/parse_dnsperf.py" "${case_dir}/dnsperf.log" \
        >"${case_dir}/client.json"
      jq -e '
        .sent > 0 and .completed >= 0 and .lost >= 0 and
        .sent == (.completed + .lost) and
        .histogram_answers == .completed and
        ([.response_codes[]] | add // 0) == .completed and
        .p50_latency_us != null and .p95_latency_us != null and
        .p99_latency_us != null
      ' "${case_dir}/client.json" >/dev/null
      if grep -Eq '^\[(Unexpected|Error|Fatal)\]' "${case_dir}/dnsperf.log"; then
        echo "dnsperf reported an unexpected/error condition in ${case_dir}" >&2
        exit 1
      fi
      jq -r \
        --arg target "${server_ip}" --arg rate "${rate}" \
        --arg threads "${dnsperf_threads}" '
        "target=\($target) port=53 offered_rate=\($rate) " +
        "duration_sec=\(.run_time_s) threads=\($threads) " +
        "offered=\(.sent) sent=\(.sent) received=\(.completed) lost=\(.lost) " +
        "qps_sent=\(.sent_qps) qps_received=\(.completed_qps) " +
        "loss_pct=\(100 - .completion_percent) " +
        "avg_us=\(.average_latency_s * 1000000) " +
        "p50_us=\(.p50_latency_us) p95_us=\(.p95_latency_us) " +
        "p99_us=\(.p99_latency_us) client_tool=dnsperf"
      ' "${case_dir}/client.json" | tee "${case_dir}/client.log"
      ;;
  esac
  capture_system "${case_dir}" after
  after="$(backend_requests)"
  printf 'backend_before=%s backend_after=%s backend_delta=%s\n' \
    "${before}" "${after}" "$(( after - before ))" \
    >"${case_dir}/backend.log"
  if [[ "${client_tool}" == burst ]]; then
    if [[ "${strict_validation}" -eq 1 ]]; then
      grep -q 'invalid=0' "${case_dir}/client.log"
    fi
    grep -q 'send_errors=0' "${case_dir}/client.log"
    grep -q 'unexpected=0' "${case_dir}/client.log"
  fi
  loader_stop
}

run_resperf_case()
{
  local mode="$1" repetition="$2"
  local before after case_dir plot_file status
  case_dir="${out_dir}/resperf/${mode}/rep-${repetition}"
  plot_file="${case_dir}/resperf.plot"
  mkdir -p "${case_dir}"
  loader_start "${mode}"
  ip netns exec "${client_ns}" "${build_dir}/dns_burst_client" \
    --target "${server_ip}" --port 53 --rate 20000 \
    --duration "${warmup_duration}" --threads "${threads}" --batch "${batch}" \
    --timeout-us "${timeout_us}" --cpu-base "${cpu_base}" \
    --queries "${out_dir}/queries.txt" >"${case_dir}/warmup.log"
  grep -q 'invalid=0' "${case_dir}/warmup.log"
  before="$(backend_requests)"
  capture_system "${case_dir}" before
  set +e
  LC_ALL=C ip netns exec "${client_ns}" taskset -c "${resperf_cpu_list}" \
    "${resperf_bin}" -s "${server_ip}" -p 53 \
    -d "${out_dir}/queries.txt" -r "${resperf_ramp}" \
    -m "${resperf_max_qps}" -c 0 -L 100 -C "${resperf_clients}" \
    -q "${resperf_outstanding}" -t 1 -R -F 0 -P "${plot_file}" -W \
    >"${case_dir}/resperf.log" 2>&1
  status=$?
  set -e
  printf '%s\n' "${status}" >"${case_dir}/resperf.exit"
  capture_system "${case_dir}" after
  after="$(backend_requests)"
  printf 'backend_before=%s backend_after=%s backend_delta=%s\n' \
    "${before}" "${after}" "$(( after - before ))" \
    >"${case_dir}/backend.log"
  [[ "${status}" -eq 0 ]]
  grep -q '^\[Status\] Testing complete' "${case_dir}/resperf.log"
  grep -q '^  Maximum throughput:' "${case_dir}/resperf.log"
  grep -q '^# time target_qps actual_qps responses_per_sec' "${plot_file}"
  loader_stop
}

run_smoke()
{
  local mode="$1" expected="$2"
  local smoke_rate=1000
  local before after received delta
  loader_start "${mode}"
  before="$(backend_requests)"
  ip netns exec "${client_ns}" "${build_dir}/dns_burst_client" \
    --target "${server_ip}" --port 53 --rate "${smoke_rate}" \
    --duration 1 --threads 1 --batch 1 --timeout-us 50000 --cpu-base 2 \
    --queries "${out_dir}/queries.txt" \
    >"${out_dir}/${mode}/smoke.log"
  after="$(backend_requests)"
  received="$(awk '{for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="received"){print a[2];exit}}}' "${out_dir}/${mode}/smoke.log")"
  delta=$(( after - before ))
  printf 'received=%s backend_delta=%s expected_backend_fraction=%s\n' \
    "${received}" "${delta}" "${expected}" \
    >"${out_dir}/${mode}/smoke-backend.log"
  [[ "${received}" -gt 900 ]]
  case "${mode}" in
    nohook) [[ "${delta}" -eq "${received}" ]] ;;
    xpress|linux-accel) awk -v d="${delta}" -v r="${received}" -v e="${expected}" 'BEGIN{f=d/r;exit !(f>e-0.06&&f<e+0.06)}' ;;
  esac
  loader_stop
}

run_correctness()
{
  local mode="$1"
  loader_start "${mode}"
  ip netns exec "${client_ns}" \
    python3 "${repo_dir}/bench/radar_dns_correctness.py" \
    --server "${server_ip}" --port 53 --domain "${domain}" \
    >"${out_dir}/${mode}/correctness.json"
  jq -e '.passed == true' "${out_dir}/${mode}/correctness.json" >/dev/null
  loader_stop
}

xpress_backend_fraction="$(jq -r '1 - (.xpress_preloaded_hit_percent / 100)' "${out_dir}/corpus-manifest.json")"
linux_backend_fraction="$(jq -r '1 - (.preloaded_hit_percent / 100)' "${out_dir}/corpus-manifest.json")"

for mode in nohook xpress linux-accel; do
  run_correctness "${mode}"
  case "${mode}" in
    nohook) run_smoke "${mode}" 1.000 ;;
    xpress) run_smoke "${mode}" "${xpress_backend_fraction}" ;;
    linux-accel) run_smoke "${mode}" "${linux_backend_fraction}" ;;
  esac
done

if [[ "${run_resperf}" -eq 1 ]]; then
  mkdir -p "${out_dir}/resperf"/{nohook,xpress,linux-accel}
  for repetition in $(seq 1 "${resperf_repetitions}"); do
    case "$(( (repetition - 1) % 3 + 1 ))" in
      1) modes=(nohook xpress linux-accel) ;;
      2) modes=(linux-accel nohook xpress) ;;
      3) modes=(xpress linux-accel nohook) ;;
    esac
    for mode in "${modes[@]}"; do
      run_resperf_case "${mode}" "${repetition}"
    done
  done
fi

for repetition in $(seq 1 "${repetitions}"); do
  order_index=$(( (repetition - 1) % 6 + 1 ))
  case "${order_index}" in
    1) modes=(nohook xpress linux-accel) ;;
    2) modes=(linux-accel xpress nohook) ;;
    3) modes=(xpress nohook linux-accel) ;;
    4) modes=(nohook linux-accel xpress) ;;
    5) modes=(linux-accel nohook xpress) ;;
    6) modes=(xpress linux-accel nohook) ;;
  esac
  for mode in "${modes[@]}"; do
    run_case "${mode}" "${repetition}"
  done
done
loader_stop

median()
{
  local mode="$1" name="$2"
  for repetition in $(seq 1 "${repetitions}"); do
    metric "${out_dir}/${mode}/rep-${repetition}/client.log" "${name}"
  done | sort -g | awk '
    { value[NR]=$1 }
    END {
      if (NR % 2) print value[(NR+1)/2]
      else printf "%.6f\n", (value[NR/2] + value[NR/2+1]) / 2
    }'
}

median_backend()
{
  local mode="$1"
  for repetition in $(seq 1 "${repetitions}"); do
    metric "${out_dir}/${mode}/rep-${repetition}/backend.log" backend_delta
  done | sort -g | awk '
    { value[NR]=$1 }
    END {
      if (NR % 2) print value[(NR+1)/2]
      else printf "%.6f\n", (value[NR/2] + value[NR/2+1]) / 2
    }'
}

: >"${out_dir}/medians.txt"
for mode in nohook xpress linux-accel; do
  sent="$(median "${mode}" sent)"
  received="$(median "${mode}" received)"
  qps="$(median "${mode}" qps_received)"
  p50="$(median "${mode}" p50_us)"
  p95="$(median "${mode}" p95_us)"
  p99="$(median "${mode}" p99_us)"
  loss="$(median "${mode}" loss_pct)"
  backend="$(median_backend "${mode}")"
  printf '%s sent=%s received=%s qps=%s p50_us=%s p95_us=%s p99_us=%s loss_pct=%s backend=%s\n' \
    "${mode}" "${sent}" "${received}" "${qps}" "${p50}" "${p95}" \
    "${p99}" "${loss}" "${backend}" \
    >>"${out_dir}/medians.txt"
done

baseline_qps="$(metric "${out_dir}/medians.txt" qps)"
baseline_p99="$(metric "${out_dir}/medians.txt" p99_us)"
{
  echo "# ${source_profile}: ${client_tool} XDP competitor benchmark"
  echo
  echo '| mode | median completed QPS | p50 us | p95 us | p99 us | loss % | backend queries | QPS / nohook | nohook p99 / mode p99 | backend offload |'
  echo '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
  while read -r mode sent_field received_field qps_field p50_field p95_field p99_field loss_field backend_field; do
    sent="${sent_field#sent=}"
    received="${received_field#received=}"
    qps="${qps_field#qps=}"
    p50="${p50_field#p50_us=}"
    p95="${p95_field#p95_us=}"
    p99="${p99_field#p99_us=}"
    loss="${loss_field#loss_pct=}"
    backend="${backend_field#backend=}"
    qps_ratio="$(awk -v a="${qps}" -v b="${baseline_qps}" 'BEGIN{printf "%.3f",a/b}')"
    p99_ratio="$(awk -v a="${baseline_p99}" -v b="${p99}" 'BEGIN{printf "%.3f",a/b}')"
    offload="$(awk -v r="${received}" -v b="${backend}" -v s="${sent}" \
      'BEGIN{f=r-b;if(f<0)f=0;printf "%.1f%%",100*f/s}')"
    printf '| %s | %s | %s | %s | %s | %s | %s | %sx | %sx | %s |\n' \
      "${mode}" "${qps}" "${p50}" "${p95}" "${p99}" "${loss}" \
      "${backend}" "${qps_ratio}" "${p99_ratio}" "${offload}"
  done <"${out_dir}/medians.txt"
} >"${out_dir}/summary.md"

bpftool net show >"${out_dir}/health/attachments-after.txt"
for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
  printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done >"${out_dir}/health/kubernetes-after.txt"
cmp -s "${out_dir}/health/kubernetes-before.txt" \
  "${out_dir}/health/kubernetes-after.txt"
cmp -s "${out_dir}/health/attachments-before.txt" \
  "${out_dir}/health/attachments-after.txt"
cat "${out_dir}/summary.md"
echo "artifacts=${out_dir}"
