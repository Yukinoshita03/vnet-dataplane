#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/openstack-workload-evidence/$(date +%Y%m%d-%H%M%S)}"
sudo_pass="${SUDO_PASS:-}"
duration="${DURATION:-8}"
iface="${IFACE:-}"
iface_list="${IFACES:-br-int br-ex ens33}"
grpc_port="${GRPC_PORT:-50051}"
dns_domain="${DNS_DOMAIN:-example.test}"
srv_if="${SRV_IF:-veth_os_srv}"
cli_if="${CLI_IF:-veth_os_cli}"
netns="${NETNS:-osworkload}"
srv_ip="${SRV_IP:-10.60.0.1}"
cli_ip="${CLI_IP:-10.60.0.2}"
requests="${REQUESTS:-1000}"
warmup="${WARMUP:-50}"
client_timeout="${CLIENT_TIMEOUT:-1.0}"
traffic_cmd="${OPENSTACK_TRAFFIC_CMD:-}"
target_ip="${OPENSTACK_TARGET_IP:-}"
openrc="${OPENRC:-/opt/stack/devstack/openrc}"

run_sudo() {
  if [[ -n "${sudo_pass}" ]]; then
    printf '%s\n' "${sudo_pass}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

capture() {
  local name="$1"
  shift
  {
    echo "\$ $*"
    "$@"
  } > "${out_dir}/${name}.log" 2>&1 || true
}

capture_sudo() {
  local name="$1"
  shift
  {
    echo "\$ sudo $*"
    run_sudo "$@"
  } > "${out_dir}/${name}.log" 2>&1 || true
}

choose_iface() {
  if [[ -n "${iface}" ]]; then
    echo "${iface}"
    return 0
  fi
  local candidate
  for candidate in ${iface_list}; do
    if ip link show "${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

cleanup() {
  run_sudo pkill -TERM -f "dns_monitor --dev ${workload_iface:-}" >/dev/null 2>&1 || true
  run_sudo pkill -TERM -f "grpc_monitor --dev ${workload_iface:-}" >/dev/null 2>&1 || true
  run_sudo pkill -TERM -f "openstack_workload_dns_stub.py" >/dev/null 2>&1 || true
  run_sudo pkill -TERM -f "openstack_workload_tcp_server.py" >/dev/null 2>&1 || true
  run_sudo ip netns del "${netns}" >/dev/null 2>&1 || true
  run_sudo ip link del "${srv_if}" >/dev/null 2>&1 || true
}

write_helpers() {
  cat > "${out_dir}/openstack_workload_dns_stub.py" <<'PY'
#!/usr/bin/env python3
import socket
import sys

bind_ip = sys.argv[1]
domain = sys.argv[2].rstrip(".")
answer = bytes(int(x) for x in sys.argv[3].split("."))
labels = domain.split(".")
qname = b"".join(bytes([len(x)]) + x.encode() for x in labels) + b"\x00\x00\x01\x00\x01"
answer_suffix = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + answer

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind((bind_ip, 53))
while True:
    data, addr = sock.recvfrom(512)
    if len(data) >= 12 and data[12:] == qname:
        resp = data[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + data[12:] + answer_suffix
    else:
        resp = data[:2] + b"\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00" + data[12:]
    sock.sendto(resp, addr)
PY

  cat > "${out_dir}/openstack_workload_tcp_server.py" <<'PY'
#!/usr/bin/env python3
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind((host, port))
sock.listen(1024)
while True:
    conn, _ = sock.accept()
    with conn:
        data = conn.recv(4096)
        if data:
            conn.sendall(b"ok")
PY

  cat > "${out_dir}/openstack_workload_client.py" <<'PY'
#!/usr/bin/env python3
import socket
import struct
import sys
import time

mode = sys.argv[1]
host = sys.argv[2]
count = int(sys.argv[3])
warmup = int(sys.argv[4])
timeout = float(sys.argv[6])
samples = []
failed = 0

def percentile(values, p):
    if not values:
        return 0.0
    return values[int((len(values) - 1) * p)]

start_all = time.time()
for i in range(count + warmup):
    if time.time() - start_all > max(5.0, (count + warmup) * timeout):
        failed += count + warmup - i
        break
    start = time.time()
    try:
        if mode == "dns":
            domain = sys.argv[5].rstrip(".")
            qname = b"".join(bytes([len(x)]) + x.encode() for x in domain.split(".")) + b"\x00\x00\x01\x00\x01"
            query = struct.pack("!H", i & 0xffff) + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + qname
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                sock.settimeout(timeout)
                sock.sendto(query, (host, 53))
                sock.recvfrom(512)
            finally:
                sock.close()
        else:
            port = int(sys.argv[5])
            with socket.create_connection((host, port), timeout=timeout) as conn:
                conn.settimeout(timeout)
                conn.sendall(b"hello")
                conn.recv(16)
        elapsed = (time.time() - start) * 1000000.0
        if i >= warmup:
            samples.append(elapsed)
    except Exception:
        failed += 1

elapsed_all = time.time() - start_all
samples.sort()
avg = sum(samples) / len(samples) if samples else 0.0
qps = len(samples) / elapsed_all if elapsed_all > 0 else 0.0
print(
    f"mode={mode} count={len(samples)} failed={failed} qps={qps:.2f} "
    f"avg_us={avg:.2f} p50_us={percentile(samples, 0.50):.2f} "
    f"p95_us={percentile(samples, 0.95):.2f} p99_us={percentile(samples, 0.99):.2f}"
)
sys.exit(0 if samples else 1)
PY
}

start_monitor() {
  local name="$1"
  shift
  local log="${out_dir}/${name}.log"
  if [[ -n "${sudo_pass}" ]]; then
    (cd "${repo_dir}" && printf '%s\n' "${sudo_pass}" | sudo -S timeout --signal=INT --kill-after=2s "${duration}s" "$@") > "${log}" 2>&1 &
  else
    (cd "${repo_dir}" && sudo timeout --signal=INT --kill-after=2s "${duration}s" "$@") > "${log}" 2>&1 &
  fi
  echo $!
}

run_fallback_workload() {
  workload_mode="ovs-host-netns-fallback"
  workload_iface="${srv_if}"
  cleanup
  run_sudo ip netns add "${netns}"
  run_sudo ip link add "${srv_if}" type veth peer name "${cli_if}"
  run_sudo ip link set "${cli_if}" netns "${netns}"
  run_sudo ip addr add "${srv_ip}/24" dev "${srv_if}"
  run_sudo ip link set "${srv_if}" up
  run_sudo ip netns exec "${netns}" ip addr add "${cli_ip}/24" dev "${cli_if}"
  run_sudo ip netns exec "${netns}" ip link set lo up
  run_sudo ip netns exec "${netns}" ip link set "${cli_if}" up

  if [[ -n "${sudo_pass}" ]]; then
    nohup sh -c "printf '%s\n' '${sudo_pass}' | sudo -S python3 '${out_dir}/openstack_workload_dns_stub.py' '${srv_ip}' '${dns_domain}' '10.0.0.123'" > "${out_dir}/dns-server.log" 2>&1 &
  else
    nohup sudo python3 "${out_dir}/openstack_workload_dns_stub.py" "${srv_ip}" "${dns_domain}" "10.0.0.123" > "${out_dir}/dns-server.log" 2>&1 &
  fi
  sleep 1
  local dns_pid
  dns_pid="$(start_monitor dns-monitor "${repo_dir}/build/dns_monitor" --dev "${workload_iface}" --hook tc --timeout-ms 1000)"
  sleep 1
  run_sudo ip netns exec "${netns}" python3 "${out_dir}/openstack_workload_client.py" dns "${srv_ip}" "${requests}" "${warmup}" "${dns_domain}" "${client_timeout}" > "${out_dir}/dns-client.log" || true
  run_sudo pkill -TERM -f "dns_monitor --dev ${workload_iface}" >/dev/null 2>&1 || true
  sleep 1
  run_sudo pkill -TERM -f "openstack_workload_dns_stub.py" >/dev/null 2>&1 || true

  if [[ -n "${sudo_pass}" ]]; then
    nohup sh -c "printf '%s\n' '${sudo_pass}' | sudo -S python3 '${out_dir}/openstack_workload_tcp_server.py' '${srv_ip}' '${grpc_port}'" > "${out_dir}/grpc-server.log" 2>&1 &
  else
    nohup sudo python3 "${out_dir}/openstack_workload_tcp_server.py" "${srv_ip}" "${grpc_port}" > "${out_dir}/grpc-server.log" 2>&1 &
  fi
  sleep 1
  local grpc_pid
  grpc_pid="$(start_monitor grpc-monitor "${repo_dir}/build/grpc_monitor" --dev "${workload_iface}" --port "${grpc_port}" --timeout-ms 1000)"
  sleep 1
  run_sudo ip netns exec "${netns}" python3 "${out_dir}/openstack_workload_client.py" tcp "${srv_ip}" "${requests}" "${warmup}" "${grpc_port}" "${client_timeout}" > "${out_dir}/grpc-client.log" || true
  run_sudo pkill -TERM -f "grpc_monitor --dev ${workload_iface}" >/dev/null 2>&1 || true
  sleep 1
  run_sudo pkill -TERM -f "openstack_workload_tcp_server.py" >/dev/null 2>&1 || true
}

run_external_workload() {
  workload_mode="external-openstack-workload"
  workload_iface="${openstack_iface}"
  local dns_pid grpc_pid
  dns_pid="$(start_monitor dns-monitor "${repo_dir}/build/dns_monitor" --dev "${workload_iface}" --hook tc --timeout-ms 1000)"
  grpc_pid="$(start_monitor grpc-monitor "${repo_dir}/build/grpc_monitor" --dev "${workload_iface}" --port "${grpc_port}" --timeout-ms 1000)"
  sleep 1
  if [[ -n "${target_ip}" ]]; then
    python3 "${out_dir}/openstack_workload_client.py" dns "${target_ip}" "${requests}" "${warmup}" "${dns_domain}" "${client_timeout}" > "${out_dir}/dns-client.log" || true
    python3 "${out_dir}/openstack_workload_client.py" tcp "${target_ip}" "${requests}" "${warmup}" "${grpc_port}" "${client_timeout}" > "${out_dir}/grpc-client.log" || true
    echo "target_ip=${target_ip} grpc_port=${grpc_port}" > "${out_dir}/external-traffic.log"
  else
    bash -lc "${traffic_cmd}" > "${out_dir}/external-traffic.log" 2>&1 || true
    echo "external traffic command completed; inspect external-traffic.log" > "${out_dir}/dns-client.log"
    echo "external traffic command completed; inspect external-traffic.log" > "${out_dir}/grpc-client.log"
  fi
  run_sudo pkill -TERM -f "dns_monitor --dev ${workload_iface}" >/dev/null 2>&1 || true
  run_sudo pkill -TERM -f "grpc_monitor --dev ${workload_iface}" >/dev/null 2>&1 || true
  sleep 1
}

need_cmd ip
need_cmd python3
need_cmd awk
if [[ ! -x "${repo_dir}/build/dns_monitor" || ! -x "${repo_dir}/build/grpc_monitor" ]]; then
  echo "missing monitor binaries; run ./scripts/build_linux.sh first" >&2
  exit 1
fi

mkdir -p "${out_dir}"
trap cleanup EXIT
write_helpers

openstack_iface="$(choose_iface || true)"
if [[ -z "${openstack_iface}" ]]; then
  echo "No OpenStack candidate interface found in IFACES='${iface_list}'" >&2
  exit 1
fi

capture uname uname -a
capture ip_link ip -br link
capture ip_addr ip -br addr
capture route ip route
capture_sudo tc_qdisc tc qdisc show
capture_sudo ovs_show ovs-vsctl show
capture_sudo virsh_domains virsh list --all
if command -v openstack >/dev/null 2>&1; then
  if [[ -f "${openrc}" ]]; then
    bash -lc "source '${openrc}' admin admin >/dev/null 2>&1 || source '${openrc}' >/dev/null 2>&1; openstack hypervisor list; openstack server list --all-projects; openstack network list; openstack port list" > "${out_dir}/openstack.log" 2>&1 || true
  else
    capture openstack openstack hypervisor list
  fi
else
  echo "openstack CLI not found" > "${out_dir}/openstack.log"
fi
ip -br link show "${openstack_iface}" > "${out_dir}/openstack-iface.log" 2>&1 || true

workload_mode=""
workload_iface=""
if [[ -n "${traffic_cmd}" || -n "${target_ip}" ]]; then
  run_external_workload
else
  run_fallback_workload
fi

dns_line="$(cat "${out_dir}/dns-client.log" 2>/dev/null || true)"
grpc_line="$(cat "${out_dir}/grpc-client.log" 2>/dev/null || true)"
dns_metrics="$(grep -E 'dns_metrics|query|response|ringbuf|events' "${out_dir}/dns-monitor.log" | tail -1 || true)"
grpc_metrics="$(grep 'grpc_metrics' "${out_dir}/grpc-monitor.log" | tail -1 || true)"

cat > "${out_dir}/summary.md" <<MD
# OpenStack / OVS Workload Evidence

| field | value |
| --- | --- |
| openstack_iface | ${openstack_iface} |
| workload_mode | ${workload_mode} |
| workload_iface | ${workload_iface} |
| openstack_target_ip | ${target_ip:-none} |
| requests | ${requests} |
| warmup | ${warmup} |
| client_timeout_sec | ${client_timeout} |
| grpc_port | ${grpc_port} |

## Claim Boundary

If \`OPENSTACK_TRAFFIC_CMD\` is set, this script records real workload traffic on the selected OpenStack/OVS interface.
Without \`OPENSTACK_TRAFFIC_CMD\`, it runs an isolated host \`netns + veth\` fallback and keeps the OpenStack evidence to attach-point and environment proof. The fallback is useful for regression, but it must not be described as VM-to-VM traffic.

## Results

DNS client: ${dns_line}

gRPC transport client: ${grpc_line}

DNS monitor: ${dns_metrics}

gRPC monitor: ${grpc_metrics}

## Collected Evidence

- \`openstack.log\`
- \`openstack-iface.log\`
- \`ovs_show.log\`
- \`virsh_domains.log\`
- \`ip_link.log\`
- \`tc_qdisc.log\`
- \`dns-monitor.log\`
- \`grpc-monitor.log\`
- \`dns-client.log\`
- \`grpc-client.log\`
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
