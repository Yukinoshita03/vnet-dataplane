#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 && "$(uname -s)" == Linux ]] || exit 1
mode="${1:-system}"
[[ "${mode}" == system || "${mode}" == afxdp ]] || exit 2
tag="$(( $$ % 80000 + 10000 ))"
client_ns="oud-c-${tag}"
server_ns="oud-s-${tag}"
client_host="oud-hc-${tag}"
client_peer="oud-pc-${tag}"
server_host="oud-hs-${tag}"
server_peer="oud-ps-${tag}"
bridge="oud-b-${tag}"
server_pid=""

cleanup()
{
  set +e
  [[ -z "${server_pid}" ]] || kill -TERM "${server_pid}" 2>/dev/null
  [[ -z "${server_pid}" ]] || wait "${server_pid}" 2>/dev/null
  ovs-vsctl --if-exists del-br "${bridge}" >/dev/null 2>&1
  ip netns del "${client_ns}" >/dev/null 2>&1
  ip netns del "${server_ns}" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT INT TERM

ip netns add "${client_ns}"
ip netns add "${server_ns}"
ip link add "${client_host}" type veth peer name "${client_peer}"
ip link add "${server_host}" type veth peer name "${server_peer}"
ip link set "${client_peer}" netns "${client_ns}"
ip link set "${server_peer}" netns "${server_ns}"
ovs-vsctl --may-exist add-br "${bridge}" -- set Bridge "${bridge}" \
  datapath_type=netdev fail-mode=standalone
ovs-vsctl add-port "${bridge}" "${client_host}" -- set Interface "${client_host}" type="${mode}" \
  $(if [[ "${mode}" == afxdp ]]; then printf 'options:xdp-mode=generic'; fi)
ovs-vsctl add-port "${bridge}" "${server_host}" -- set Interface "${server_host}" type="${mode}" \
  $(if [[ "${mode}" == afxdp ]]; then printf 'options:xdp-mode=generic'; fi)
ovs-ofctl del-flows "${bridge}" >/dev/null 2>&1 || true
ovs-ofctl add-flow "${bridge}" 'actions=NORMAL'
ip link set "${client_host}" up
ip link set "${server_host}" up
ip netns exec "${client_ns}" ip link set lo up
ip netns exec "${server_ns}" ip link set lo up
ip netns exec "${client_ns}" ip addr add 198.19.78.1/24 dev "${client_peer}"
ip netns exec "${server_ns}" ip addr add 198.19.78.2/24 dev "${server_peer}"
ip netns exec "${client_ns}" ip link set "${client_peer}" up
ip netns exec "${server_ns}" ip link set "${server_peer}" up
ethtool -K "${client_host}" tx off rx off tso off gso off gro off ufo off 2>/dev/null || true
ethtool -K "${server_host}" tx off rx off tso off gso off gro off ufo off 2>/dev/null || true
ip netns exec "${client_ns}" ethtool -K "${client_peer}" tx off rx off tso off gso off gro off ufo off 2>/dev/null || true
ip netns exec "${server_ns}" ethtool -K "${server_peer}" tx off rx off tso off gso off gro off ufo off 2>/dev/null || true
ip netns exec "${client_ns}" ping -c 1 -W 1 198.19.78.2

ip netns exec "${server_ns}" python3 -u -c \
  'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("0.0.0.0",19001)); s.settimeout(5); print("server-ready",flush=True); data,peer=s.recvfrom(2048); print("server-recv",data,peer,flush=True); s.sendto(b"pong-ok",peer)' \
  >/tmp/ovs-afxdp-paper/python-server-${tag}.log 2>&1 &
server_pid=$!
sleep 0.3
client_rc=0
ip netns exec "${client_ns}" python3 -u -c \
  'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2); s.sendto(b"ping",("198.19.78.2",19001)); print("client-recv",s.recvfrom(2048),flush=True)' || client_rc=$?
cat "/tmp/ovs-afxdp-paper/python-server-${tag}.log"
ovs-ofctl dump-flows "${bridge}"
ovs-ofctl dump-ports "${bridge}"
ip -s link show dev "${client_host}"
ip -s link show dev "${server_host}"
ip netns exec "${client_ns}" ip -s link show dev "${client_peer}"
ip netns exec "${server_ns}" ip -s link show dev "${server_peer}"
exit "${client_rc}"
