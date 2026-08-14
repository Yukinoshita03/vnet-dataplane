#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/af-xdp-vs-xdp-bench}"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/af-xdp-vs-xdp/$(date +%Y%m%d-%H%M%S)}"
repetitions="${REPETITIONS:-3}"
threads="${THREADS:-8}"
requests="${REQUESTS:-10000}"
warmup="${WARMUP:-500}"

if [[ "$(uname -s)" != Linux || ${EUID} -ne 0 ]]; then
  echo "Run this benchmark as root on Linux" >&2
  exit 1
fi

mkdir -p "${build_dir}" "${out_dir}"/{health,nohook,af-xdp-copy,xdp-tx}
tag=$(( $$ % 100000 ))
client_ns="axc${tag}"
server_ns="axs${tag}"
client_host="axch${tag}"
client_peer="axcp${tag}"
server_host="axsh${tag}"
server_peer="axsp${tag}"
bridge="axb${tag}"
server_ip="198.19.0.3"
server_port=9000
server_pid=""
responder_pid=""
loader_pid=""

cleanup()
{
  set +e
  [[ -z "${loader_pid}" ]] || kill -TERM "${loader_pid}" 2>/dev/null
  [[ -z "${responder_pid}" ]] || kill -TERM "${responder_pid}" 2>/dev/null
  [[ -z "${server_pid}" ]] || kill -TERM "${server_pid}" 2>/dev/null
  [[ -z "${loader_pid}" ]] || wait "${loader_pid}" 2>/dev/null
  [[ -z "${responder_pid}" ]] || wait "${responder_pid}" 2>/dev/null
  [[ -z "${server_pid}" ]] || wait "${server_pid}" 2>/dev/null
  ip netns del "${client_ns}" 2>/dev/null
  ip netns del "${server_ns}" 2>/dev/null
  ip link del dev "${bridge}" 2>/dev/null
}
trap cleanup EXIT INT TERM

multiarch_include="/usr/include/$(gcc -print-multiarch 2>/dev/null || true)"
bpf_includes=("-I${repo_dir}/src/include" "-I${repo_dir}/include")
[[ ! -d "${multiarch_include}" ]] || bpf_includes+=("-I${multiarch_include}")
clang -target bpf -O2 -g "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/udp_fastpath.c" \
  -o "${build_dir}/udp_fastpath.bpf.o"
clang -target bpf -O2 -g "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/af_xdp_udp_redirect.c" \
  -o "${build_dir}/af_xdp_udp_redirect.bpf.o"
read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
read -r -a libxdp_flags <<< "$(pkg-config --cflags --libs libxdp)"
c++ -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/src/udp_fastpath.cpp" \
  "${repo_dir}/src/udp_fastpath_policy.cpp" \
  -o "${build_dir}/udp_fastpath" "${libbpf_flags[@]}"
c++ -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror -pthread \
  "${repo_dir}/bench/udp_fastpath_bench.cpp" \
  -o "${build_dir}/udp_fastpath_bench"
c++ -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  "${repo_dir}/bench/af_xdp_udp_responder.cpp" \
  -o "${build_dir}/af_xdp_udp_responder" "${libxdp_flags[@]}" \
  "${libbpf_flags[@]}"

{
  echo "kernel=$(uname -r)"
  echo "libxdp=$(pkg-config --modversion libxdp)"
  echo "libbpf=$(pkg-config --modversion libbpf)"
  echo "repetitions=${repetitions}"
  echo "threads=${threads}"
  echo "requests=${requests}"
  echo "warmup=${warmup}"
} >"${out_dir}/metadata.txt"
bpftool net show >"${out_dir}/health/attachments-before.txt"
for unit in kubelet containerd kubernetes-haproxy; do
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
ip netns exec "${client_ns}" ip link set "${client_peer}" address 02:00:00:00:10:11
ip netns exec "${server_ns}" ip link set "${server_peer}" address 02:00:00:00:10:22
ip netns exec "${client_ns}" ip addr add 198.19.0.2/24 dev "${client_peer}"
ip netns exec "${server_ns}" ip addr add 198.19.0.3/24 dev "${server_peer}"
ip netns exec "${client_ns}" ip link set "${client_peer}" up
ip netns exec "${server_ns}" ip link set "${server_peer}" up

ip netns exec "${server_ns}" "${build_dir}/udp_fastpath_bench" \
  --server "${server_ip}:${server_port}" >"${out_dir}/backend.log" 2>&1 &
server_pid=$!
sleep 0.2
ip netns exec "${client_ns}" ping -c 1 -W 1 "${server_ip}" \
  >"${out_dir}/health/ping.txt"

run_case()
{
  local mode="$1"
  local repetition="$2"
  ip netns exec "${client_ns}" "${build_dir}/udp_fastpath_bench" \
    --client "${server_ip}:${server_port}" --threads "${threads}" \
    --requests "${requests}" --warmup "${warmup}" \
    | tee "${out_dir}/${mode}/rep-${repetition}.log"
  grep -q 'failed=0' "${out_dir}/${mode}/rep-${repetition}.log"
}

for repetition in $(seq 1 "${repetitions}"); do
  run_case nohook "${repetition}"
done

"${build_dir}/af_xdp_udp_responder" --dev "${client_host}" --queue 0 --copy \
  --bpf-object "${build_dir}/af_xdp_udp_redirect.bpf.o" \
  >"${out_dir}/af-xdp-loader.log" 2>&1 &
responder_pid=$!
for _ in $(seq 1 50); do
  grep -q 'attached' "${out_dir}/af-xdp-loader.log" 2>/dev/null && break
  kill -0 "${responder_pid}" 2>/dev/null || {
    cat "${out_dir}/af-xdp-loader.log" >&2
    exit 1
  }
  sleep 0.1
done
grep -q 'attached' "${out_dir}/af-xdp-loader.log"
for repetition in $(seq 1 "${repetitions}"); do
  run_case af-xdp-copy "${repetition}"
done
kill -TERM "${responder_pid}"
wait "${responder_pid}"
responder_pid=""
grep -Eq 'hit=[1-9][0-9]*' "${out_dir}/af-xdp-loader.log"
grep -Eq 'tx=[1-9][0-9]*' "${out_dir}/af-xdp-loader.log"

printf '%s %s %s %s %s %s\n' \
  "${client_host}" "${server_ip}" "${server_port}" \
  70696e67 706f6e672d6f6b 30 >"${out_dir}/udp-policy.conf"
"${build_dir}/udp_fastpath" --policy-file "${out_dir}/udp-policy.conf" \
  --bpf-object "${build_dir}/udp_fastpath.bpf.o" --xdp-mode generic \
  >"${out_dir}/xdp-loader.log" 2>&1 &
loader_pid=$!
for _ in $(seq 1 50); do
  ip -details link show dev "${client_host}" | grep -q 'prog/xdp' && break
  kill -0 "${loader_pid}" 2>/dev/null || {
    cat "${out_dir}/xdp-loader.log" >&2
    exit 1
  }
  sleep 0.1
done
ip -details link show dev "${client_host}" | grep -q 'prog/xdp'
for repetition in $(seq 1 "${repetitions}"); do
  run_case xdp-tx "${repetition}"
done
kill -TERM "${loader_pid}"
wait "${loader_pid}"
loader_pid=""
grep -Eq 'hit=[1-9][0-9]*' "${out_dir}/xdp-loader.log"
grep -Eq 'tx=[1-9][0-9]*' "${out_dir}/xdp-loader.log"

metric()
{
  local file="$1" name="$2"
  awk -v name="${name}" '{for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]==name){print a[2];exit}}}' "${file}"
}

median()
{
  local mode="$1" name="$2" rank=$(( (repetitions + 1) / 2 ))
  for repetition in $(seq 1 "${repetitions}"); do
    metric "${out_dir}/${mode}/rep-${repetition}.log" "${name}"
  done | sort -g | sed -n "${rank}p"
}

for mode in nohook af-xdp-copy xdp-tx; do
  qps="$(median "${mode}" qps)"
  p50="$(median "${mode}" p50_us)"
  p95="$(median "${mode}" p95_us)"
  p99="$(median "${mode}" p99_us)"
  printf '%s qps=%s p50_us=%s p95_us=%s p99_us=%s\n' \
    "${mode}" "${qps}" "${p50}" "${p95}" "${p99}" \
    >>"${out_dir}/medians.txt"
done
baseline_qps="$(awk '$1=="nohook"{for(i=1;i<=NF;i++)if($i~/^qps=/){split($i,a,"=");print a[2]}}' "${out_dir}/medians.txt")"
baseline_p99="$(awk '$1=="nohook"{for(i=1;i<=NF;i++)if($i~/^p99_us=/){split($i,a,"=");print a[2]}}' "${out_dir}/medians.txt")"
{
  echo '# AF_XDP copy vs generic XDP_TX UDP benchmark'
  echo
  echo '| mode | median QPS | median p50 us | median p95 us | median p99 us | QPS / nohook | nohook p99 / mode p99 |'
  echo '| --- | ---: | ---: | ---: | ---: | ---: | ---: |'
  while read -r mode qps_field p50_field p95_field p99_field; do
    qps="${qps_field#qps=}"
    p50="${p50_field#p50_us=}"
    p95="${p95_field#p95_us=}"
    p99="${p99_field#p99_us=}"
    qps_ratio="$(awk -v a="${qps}" -v b="${baseline_qps}" 'BEGIN{printf "%.3f",a/b}')"
    p99_ratio="$(awk -v a="${baseline_p99}" -v b="${p99}" 'BEGIN{printf "%.3f",a/b}')"
    printf '| %s | %s | %s | %s | %s | %sx | %sx |\n' \
      "${mode}" "${qps}" "${p50}" "${p95}" "${p99}" \
      "${qps_ratio}" "${p99_ratio}"
  done <"${out_dir}/medians.txt"
} >"${out_dir}/summary.md"

bpftool net show >"${out_dir}/health/attachments-after.txt"
for unit in kubelet containerd kubernetes-haproxy; do
  printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done >"${out_dir}/health/kubernetes-after.txt"
cmp -s "${out_dir}/health/kubernetes-before.txt" "${out_dir}/health/kubernetes-after.txt"
cat "${out_dir}/summary.md"
echo "artifacts=${out_dir}"
