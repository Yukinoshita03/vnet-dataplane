#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 && "$(uname -s)" == Linux ]] || exit 1
bench_bin="${BENCH_BIN:-/tmp/ovs-afxdp-paper/udp_fastpath_bench}"
tag="$(( $$ % 80000 + 10000 ))"
client_ns="udc-${tag}"
server_ns="uds-${tag}"
client_peer="udcp-${tag}"
server_peer="udsp-${tag}"
server_pid=""

cleanup()
{
  set +e
  [[ -z "${server_pid}" ]] || kill -TERM "${server_pid}" 2>/dev/null
  [[ -z "${server_pid}" ]] || wait "${server_pid}" 2>/dev/null
  ip netns del "${client_ns}" 2>/dev/null
  ip netns del "${server_ns}" 2>/dev/null
}
trap cleanup EXIT INT TERM

ip netns add "${client_ns}"
ip netns add "${server_ns}"
ip link add "${client_peer}" type veth peer name "${server_peer}"
ip link set "${client_peer}" netns "${client_ns}"
ip link set "${server_peer}" netns "${server_ns}"
ip netns exec "${client_ns}" ip link set lo up
ip netns exec "${server_ns}" ip link set lo up
ip netns exec "${client_ns}" ip addr add 198.19.77.1/24 dev "${client_peer}"
ip netns exec "${server_ns}" ip addr add 198.19.77.2/24 dev "${server_peer}"
ip netns exec "${client_ns}" ip link set "${client_peer}" up
ip netns exec "${server_ns}" ip link set "${server_peer}" up
ip netns exec "${client_ns}" ping -c 2 -W 1 198.19.77.2
ip netns exec "${server_ns}" "${bench_bin}" --server 198.19.77.2:19000 \
  >/tmp/ovs-afxdp-paper/direct-server.log 2>&1 &
server_pid=$!
sleep 0.2
ip netns exec "${client_ns}" "${bench_bin}" --client 198.19.77.2:19000 \
  --threads 1 --requests 100 --warmup 10
