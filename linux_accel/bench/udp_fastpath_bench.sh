#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/udp-fastpath-bench}"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/udp-fastpath-bench/$(date +%Y%m%d-%H%M%S)}"
threads="${THREADS:-4}"
requests="${REQUESTS:-10000}"
warmup="${WARMUP:-200}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "UDP XDP benchmark requires Linux" >&2
  exit 1
fi
if (( EUID != 0 )); then
  echo "Run UDP XDP benchmark as root" >&2
  exit 1
fi

mkdir -p "${build_dir}" "${out_dir}"
tag=$(( $$ % 100000 ))
client_ns="ufc${tag}"
server_ns="ufs${tag}"
client_host="ufch${tag}"
client_peer="ufcp${tag}"
server_host="ufsh${tag}"
server_peer="ufsp${tag}"
bridge="ufb${tag}"
server_ip="198.18.0.3"
server_port=9000
server_pid=""
loader_pid=""

cleanup() {
  if [[ -n "${loader_pid}" ]]; then
    kill -TERM "${loader_pid}" >/dev/null 2>&1 || true
    wait "${loader_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${server_pid}" ]]; then
    kill -TERM "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  ip netns del "${client_ns}" >/dev/null 2>&1 || true
  ip netns del "${server_ns}" >/dev/null 2>&1 || true
  ip link del dev "${bridge}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

multiarch_include="/usr/include/$(gcc -print-multiarch 2>/dev/null || true)"
bpf_includes=("-I${repo_dir}/src/include" "-I${repo_dir}/include")
if [[ -d "${multiarch_include}" ]]; then
  bpf_includes+=("-I${multiarch_include}")
fi

clang -target bpf -O2 -g "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/udp_fastpath.c" \
  -o "${build_dir}/udp_fastpath.bpf.o"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
  read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
else
  libbpf_flags=(-lbpf -lelf -lz)
fi

c++ -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/src/udp_fastpath_policy.cpp" \
  "${repo_dir}/src/udp_fastpath.cpp" \
  -o "${build_dir}/udp_fastpath" "${libbpf_flags[@]}"
c++ -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror -pthread \
  "${repo_dir}/bench/udp_fastpath_bench.cpp" \
  -o "${build_dir}/udp_fastpath_bench"

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
ip netns exec "${client_ns}" ip link set "${client_peer}" address 02:00:00:00:00:11
ip netns exec "${server_ns}" ip link set "${server_peer}" address 02:00:00:00:00:22
ip netns exec "${client_ns}" ip addr add 198.18.0.2/24 dev "${client_peer}"
ip netns exec "${server_ns}" ip addr add 198.18.0.3/24 dev "${server_peer}"
ip netns exec "${client_ns}" ip link set "${client_peer}" up
ip netns exec "${server_ns}" ip link set "${server_peer}" up

rx_packets() {
  ip -s link show dev "${server_host}" | awk '/RX:/{getline; print $2; exit}'
}

ip netns exec "${server_ns}" "${build_dir}/udp_fastpath_bench" \
  --server "${server_ip}:${server_port}" \
  >"${out_dir}/server.log" 2>&1 &
server_pid=$!
sleep 0.2
ip netns exec "${client_ns}" ping -c 1 -W 1 "${server_ip}" \
  >"${out_dir}/ping.log"

baseline_rx_before="$(rx_packets)"
ip netns exec "${client_ns}" "${build_dir}/udp_fastpath_bench" \
  --client "${server_ip}:${server_port}" --threads "${threads}" \
  --requests "${requests}" --warmup "${warmup}" \
  | tee "${out_dir}/baseline.log"
baseline_rx_after="$(rx_packets)"

printf '%s %s %s %s %s %s\n' \
  "${client_host}" "${server_ip}" "${server_port}" \
  70696e67 706f6e672d6f6b 30 >"${out_dir}/udp-policy.conf"
"${build_dir}/udp_fastpath" --policy-file "${out_dir}/udp-policy.conf" \
  --bpf-object "${build_dir}/udp_fastpath.bpf.o" --xdp-mode generic \
  >"${out_dir}/loader.log" 2>&1 &
loader_pid=$!
sleep 0.5
ip -details link show dev "${client_host}" | grep -q 'prog/xdp'

xdp_rx_before="$(rx_packets)"
ip netns exec "${client_ns}" "${build_dir}/udp_fastpath_bench" \
  --client "${server_ip}:${server_port}" --threads "${threads}" \
  --requests "${requests}" --warmup "${warmup}" \
  | tee "${out_dir}/xdp.log"
xdp_rx_after="$(rx_packets)"
kill -TERM "${loader_pid}"
wait "${loader_pid}"
loader_pid=""

kill -TERM "${server_pid}"
wait "${server_pid}"
server_pid=""

metric() {
  local file="$1"
  local name="$2"
  awk -v name="${name}" '{for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]==name){print a[2];exit}}}' "${file}"
}

baseline_qps="$(metric "${out_dir}/baseline.log" qps)"
xdp_qps="$(metric "${out_dir}/xdp.log" qps)"
baseline_p99="$(metric "${out_dir}/baseline.log" p99_us)"
xdp_p99="$(metric "${out_dir}/xdp.log" p99_us)"
baseline_rx_delta=$((baseline_rx_after - baseline_rx_before))
xdp_rx_delta=$((xdp_rx_after - xdp_rx_before))
qps_ratio="$(awk -v a="${xdp_qps}" -v b="${baseline_qps}" 'BEGIN{if(b>0)printf "%.3f",a/b;else print "0"}')"
p99_ratio="$(awk -v a="${baseline_p99}" -v b="${xdp_p99}" 'BEGIN{if(b>0)printf "%.3f",a/b;else print "0"}')"

{
  printf '# UDP XDP fast-path benchmark\n\n'
  printf '| mode | qps | p99_us | server-side RX packets |\n'
  printf '| --- | ---: | ---: | ---: |\n'
  printf '| userspace backend | %s | %s | %s |\n' \
    "${baseline_qps}" "${baseline_p99}" "${baseline_rx_delta}"
  printf '| generic XDP exact hit | %s | %s | %s |\n\n' \
    "${xdp_qps}" "${xdp_p99}" "${xdp_rx_delta}"
  printf 'QPS speedup: %sx\n\n' "${qps_ratio}"
  printf 'p99 speedup (baseline/XDP): %sx\n' "${p99_ratio}"
} >"${out_dir}/summary.md"

grep -Eq 'hit=[1-9][0-9]*' "${out_dir}/loader.log"
grep -Eq 'tx=[1-9][0-9]*' "${out_dir}/loader.log"
cat "${out_dir}/summary.md"
echo "artifacts=${out_dir}"
