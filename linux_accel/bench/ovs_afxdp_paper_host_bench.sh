#!/usr/bin/env bash
set -Eeuo pipefail

# Run on an OpenStack compute host as root.  This is an isolated OVS
# userspace-datapath experiment: it never touches br-int, a physical NIC, or
# any OpenStack VM TAP.  The topology follows the upstream OVS AF_XDP veth
# example and is therefore labelled as an OpenStack-compute-host dataplane
# result, not as a tenant-VM end-to-end result.

if [[ "$(uname -s)" != Linux || ${EUID} -ne 0 ]]; then
  echo "run this benchmark as root on Linux" >&2
  exit 1
fi

for command in ip ovs-vsctl ovs-ofctl ovs-appctl awk sort sed g++ taskset; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done

for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
  if [[ "$(systemctl is-active "${unit}" 2>/dev/null || true)" == active ]]; then
    echo "Kubernetes must stay stopped: ${unit}" >&2
    exit 1
  fi
done

bench_bin="${BENCH_BIN:-/tmp/ovs-afxdp-paper/udp_fastpath_bench}"
out_dir="${OUT_DIR:-/tmp/ovs-afxdp-paper/results-$(date +%Y%m%d-%H%M%S)}"
repetitions="${REPETITIONS:-3}"
threads="${THREADS:-4}"
requests="${REQUESTS:-20000}"
warmup="${WARMUP:-500}"
server_ip="198.19.77.2"
client_ip="198.19.77.1"
server_port="19000"

test -x "${bench_bin}" || {
  echo "benchmark binary is missing or not executable: ${bench_bin}" >&2
  exit 1
}
mkdir -p "${out_dir}"/{health,nohook,afxdp}

tag="$(( $$ % 80000 + 10000 ))"
client_ns="oa-c-${tag}"
server_ns="oa-s-${tag}"
client_host="oac-h-${tag}"
client_peer="oac-p-${tag}"
server_host="oas-h-${tag}"
server_peer="oas-p-${tag}"
bridge="oab-${tag}"
server_pid=""

cleanup_server()
{
  if [[ -n "${server_pid}" ]]; then
    kill -TERM "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
    server_pid=""
  fi
}

cleanup_topology()
{
  set +e
  cleanup_server
  ovs-vsctl --if-exists del-br "${bridge}" >/dev/null 2>&1
  ip netns del "${client_ns}" >/dev/null 2>&1
  ip netns del "${server_ns}" >/dev/null 2>&1
  ip link del dev "${client_host}" >/dev/null 2>&1
  ip link del dev "${server_host}" >/dev/null 2>&1
  return 0
}

cleanup()
{
  cleanup_topology
}
trap cleanup EXIT INT TERM

{
  echo "hostname=$(hostname)"
  echo "kernel=$(uname -r)"
  echo "ovs=$(ovs-vsctl get Open_vSwitch . ovs_version 2>/dev/null || true)"
  echo "repetitions=${repetitions}"
  echo "threads=${threads}"
  echo "requests=${requests}"
  echo "warmup=${warmup}"
  echo "topology=isolated-netns-veth-to-ovs-userspace-netdev"
  echo "kubernetes=required-inactive"
} >"${out_dir}/metadata.txt"
ovs-vsctl list-br >"${out_dir}/health/bridges-before.txt"
ovs-vsctl show >"${out_dir}/health/ovs-before.txt"
ip -br link >"${out_dir}/health/links-before.txt"
bpftool net show >"${out_dir}/health/bpftool-before.txt" 2>&1 || true
for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
  printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done >"${out_dir}/health/kubernetes-before.txt"

metric()
{
  local file="$1"
  local name="$2"
  awk -v wanted="${name}" '{for (i = 1; i <= NF; ++i) { split($i, a, "="); if (a[1] == wanted) { print a[2]; exit } }}' "${file}"
}

median_metric()
{
  local mode="$1"
  local name="$2"
  local rank=$(( (repetitions + 1) / 2 ))
  for repetition in $(seq 1 "${repetitions}"); do
    metric "${out_dir}/${mode}/rep-${repetition}.log" "${name}"
  done | sort -g | sed -n "${rank}p"
}

setup_topology()
{
  local mode="$1"
  ip netns add "${client_ns}"
  ip netns add "${server_ns}"
  ip link add "${client_host}" type veth peer name "${client_peer}"
  ip link add "${server_host}" type veth peer name "${server_peer}"
  ip link set "${client_peer}" netns "${client_ns}"
  ip link set "${server_peer}" netns "${server_ns}"

  ovs-vsctl --may-exist add-br "${bridge}" -- set Bridge "${bridge}" \
    datapath_type=netdev fail-mode=standalone
  if [[ "${mode}" == afxdp ]]; then
    ovs-vsctl add-port "${bridge}" "${client_host}" -- \
      set Interface "${client_host}" type=afxdp options:xdp-mode=generic
    ovs-vsctl add-port "${bridge}" "${server_host}" -- \
      set Interface "${server_host}" type=afxdp options:xdp-mode=generic
  else
    ovs-vsctl add-port "${bridge}" "${client_host}" -- \
      set Interface "${client_host}" type=system
    ovs-vsctl add-port "${bridge}" "${server_host}" -- \
      set Interface "${server_host}" type=system
  fi
  ovs-ofctl del-flows "${bridge}" >/dev/null 2>&1 || true
  ovs-ofctl add-flow "${bridge}" 'actions=NORMAL'

  ip link set "${client_host}" up
  ip link set "${server_host}" up
  ip netns exec "${client_ns}" ip link set lo up
  ip netns exec "${server_ns}" ip link set lo up
  ip netns exec "${client_ns}" ip link set "${client_peer}" address 02:77:00:00:00:01
  ip netns exec "${server_ns}" ip link set "${server_peer}" address 02:77:00:00:00:02
  ip netns exec "${client_ns}" ip addr add "${client_ip}/24" dev "${client_peer}"
  ip netns exec "${server_ns}" ip addr add "${server_ip}/24" dev "${server_peer}"
  ip netns exec "${client_ns}" ip link set "${client_peer}" up
  ip netns exec "${server_ns}" ip link set "${server_peer}" up
  # veth checksum metadata is not preserved by every OVS userspace path.  A
  # stale partial-checksum bit makes the UDP packet reach the peer veth but
  # get discarded by the receiving namespace.  Disable offloads only on this
  # disposable benchmark topology; never change OpenStack/TAP/physical NICs.
  ethtool -K "${client_host}" tx off rx off tso off gso off gro off ufo off \
    >/dev/null 2>&1 || true
  ethtool -K "${server_host}" tx off rx off tso off gso off gro off ufo off \
    >/dev/null 2>&1 || true
  ip netns exec "${client_ns}" ethtool -K "${client_peer}" tx off rx off tso off gso off gro off ufo off \
    >/dev/null 2>&1 || true
  ip netns exec "${server_ns}" ethtool -K "${server_peer}" tx off rx off tso off gso off gro off ufo off \
    >/dev/null 2>&1 || true

  ovs-vsctl show >"${out_dir}/${mode}/ovs-after-setup.txt"
  ovs-vsctl get Interface "${client_host}" type \
    >"${out_dir}/${mode}/client-interface-type.txt"
  ovs-vsctl get Interface "${server_host}" type \
    >"${out_dir}/${mode}/server-interface-type.txt"
  ovs-vsctl get Interface "${client_host}" status \
    >"${out_dir}/${mode}/client-interface-status.txt" 2>&1 || true
  ovs-vsctl get Interface "${server_host}" status \
    >"${out_dir}/${mode}/server-interface-status.txt" 2>&1 || true
  ip -details link show dev "${client_host}" \
    >"${out_dir}/${mode}/client-host-link.txt"
  ip -details link show dev "${server_host}" \
    >"${out_dir}/${mode}/server-host-link.txt"

  if [[ "${mode}" == afxdp ]]; then
    grep -q 'afxdp' "${out_dir}/${mode}/client-interface-type.txt"
    grep -q 'afxdp' "${out_dir}/${mode}/server-interface-type.txt"
    grep -Eq 'xdp-mode|generic|native' "${out_dir}/${mode}/client-interface-status.txt" || {
      echo "OVS AF_XDP client status did not expose xdp-mode" >&2
      cat "${out_dir}/${mode}/client-interface-status.txt" >&2
      exit 1
    }
  fi

  ip netns exec "${client_ns}" ping -c 2 -W 1 "${server_ip}" \
    >"${out_dir}/${mode}/ping.txt"
}

run_mode()
{
  local mode="$1"
  local repetition
  setup_topology "${mode}"
  ip netns exec "${server_ns}" "${bench_bin}" \
    --server "${server_ip}:${server_port}" \
    >"${out_dir}/${mode}/server.log" 2>&1 &
  server_pid=$!
  sleep 0.2
  ip netns exec "${server_ns}" ss -lnu | grep -q ":${server_port} "

  for repetition in $(seq 1 "${repetitions}"); do
    cat /proc/stat >"${out_dir}/${mode}/proc-stat-before-${repetition}.txt"
    cat /proc/softirqs >"${out_dir}/${mode}/softirqs-before-${repetition}.txt"
    cat /proc/net/softnet_stat >"${out_dir}/${mode}/softnet-before-${repetition}.txt"
    ip -s link show dev "${client_host}" \
      >"${out_dir}/${mode}/client-link-before-${repetition}.txt"
    ip netns exec "${client_ns}" "${bench_bin}" \
      --client "${server_ip}:${server_port}" --threads "${threads}" \
      --requests "${requests}" --warmup "${warmup}" \
      | tee "${out_dir}/${mode}/rep-${repetition}.log"
    cat /proc/stat >"${out_dir}/${mode}/proc-stat-after-${repetition}.txt"
    cat /proc/softirqs >"${out_dir}/${mode}/softirqs-after-${repetition}.txt"
    cat /proc/net/softnet_stat >"${out_dir}/${mode}/softnet-after-${repetition}.txt"
    ip -s link show dev "${client_host}" \
      >"${out_dir}/${mode}/client-link-after-${repetition}.txt"
    ovs-appctl dpif-netdev/pmd-stats-show \
      >"${out_dir}/${mode}/pmd-stats-${repetition}.txt" 2>&1 || true
    if ! grep -q 'failed=0' "${out_dir}/${mode}/rep-${repetition}.log"; then
      echo "${mode} repetition ${repetition} did not complete successfully" >&2
      if [[ "${ALLOW_FAILURE:-0}" != 1 ]]; then
        exit 1
      fi
    fi
  done
  cleanup_topology
}

run_mode nohook
run_mode afxdp

for mode in nohook afxdp; do
  printf '%s qps=%s p50_us=%s p95_us=%s p99_us=%s\n' \
    "${mode}" \
    "$(median_metric "${mode}" qps)" \
    "$(median_metric "${mode}" p50_us)" \
    "$(median_metric "${mode}" p95_us)" \
    "$(median_metric "${mode}" p99_us)" \
    >>"${out_dir}/medians.txt"
done

baseline_qps="$(awk '$1 == "nohook" { for (i = 1; i <= NF; ++i) if ($i ~ /^qps=/) { split($i, a, "="); print a[2] } }' "${out_dir}/medians.txt")"
baseline_p99="$(awk '$1 == "nohook" { for (i = 1; i <= NF; ++i) if ($i ~ /^p99_us=/) { split($i, a, "="); print a[2] } }' "${out_dir}/medians.txt")"
afxdp_qps="$(awk '$1 == "afxdp" { for (i = 1; i <= NF; ++i) if ($i ~ /^qps=/) { split($i, a, "="); print a[2] } }' "${out_dir}/medians.txt")"
afxdp_p99="$(awk '$1 == "afxdp" { for (i = 1; i <= NF; ++i) if ($i ~ /^p99_us=/) { split($i, a, "="); print a[2] } }' "${out_dir}/medians.txt")"
qps_ratio="$(awk -v a="${afxdp_qps}" -v b="${baseline_qps}" 'BEGIN { if (b > 0) printf "%.4f", a / b; else print "0" }')"
p99_ratio="$(awk -v a="${baseline_p99}" -v b="${afxdp_p99}" 'BEGIN { if (b > 0) printf "%.4f", a / b; else print "0" }')"

{
  echo '# OVS AF_XDP paper datapath benchmark on an OpenStack compute host'
  echo
  echo 'This is an isolated netns/veth-to-OVS userspace-netdev experiment. It does not replace br-int ports or claim an end-to-end tenant VM result.'
  echo
  echo '| mode | median QPS | median p50 us | median p95 us | median p99 us | QPS / nohook | nohook p99 / mode p99 |'
  echo '| --- | ---: | ---: | ---: | ---: | ---: | ---: |'
  while read -r mode qps_field p50_field p95_field p99_field; do
    qps="${qps_field#qps=}"
    p50="${p50_field#p50_us=}"
    p95="${p95_field#p95_us=}"
    p99="${p99_field#p99_us=}"
    qps_ratio_mode="$(awk -v a="${qps}" -v b="${baseline_qps}" 'BEGIN { if (b > 0) printf "%.4f", a / b; else print "0" }')"
    p99_ratio_mode="$(awk -v a="${baseline_p99}" -v b="${p99}" 'BEGIN { if (b > 0) printf "%.4f", a / b; else print "0" }')"
    printf '| %s | %s | %s | %s | %s | %sx | %sx |\n' \
      "${mode}" "${qps}" "${p50}" "${p95}" "${p99}" \
      "${qps_ratio_mode}" "${p99_ratio_mode}"
  done <"${out_dir}/medians.txt"
  echo
  printf 'afxdp_vs_nohook_qps=%sx\n' "${qps_ratio}"
  printf 'nohook_vs_afxdp_p99=%sx\n' "${p99_ratio}"
  printf 'correctness=all client requests completed with failed=0\n'
} | tee "${out_dir}/summary.md"

ovs-vsctl list-br >"${out_dir}/health/bridges-after.txt"
ovs-vsctl show >"${out_dir}/health/ovs-after.txt"
ip -br link >"${out_dir}/health/links-after.txt"
bpftool net show >"${out_dir}/health/bpftool-after.txt" 2>&1 || true
for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
  printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done >"${out_dir}/health/kubernetes-after.txt"
cmp -s "${out_dir}/health/bridges-before.txt" "${out_dir}/health/bridges-after.txt"
cmp -s "${out_dir}/health/kubernetes-before.txt" "${out_dir}/health/kubernetes-after.txt"
echo "artifacts=${out_dir}"
