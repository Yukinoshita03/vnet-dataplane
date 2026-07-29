#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
netns="${NETNS:-grpcstreamtest}"
server_if="${SERVER_IF:-veth_grpc_srv}"
client_if="${CLIENT_IF:-veth_grpc_cli}"
server_ip="${SERVER_IP:-10.39.0.1}"
client_ip="${CLIENT_IP:-10.39.0.2}"
port="${PORT:-50051}"
monitor_pid=""
server_pid=""
temporary_output=0

if [[ "$(id -u)" -ne 0 ]]; then
  echo "grpc_stream_correlation_test: must run as root" >&2
  exit 1
fi

if [[ ! -x "${root_dir}/build/grpc_monitor" ]]; then
  echo "missing build/grpc_monitor; run ./scripts/build_linux.sh first" >&2
  exit 1
fi

if [[ -n "${OUT_DIR:-}" ]]; then
  output_dir="${OUT_DIR}"
  mkdir -p "${output_dir}"
else
  output_dir="$(mktemp -d /tmp/vnet-grpc-stream-test.XXXXXX)"
  temporary_output=1
fi

cleanup() {
  if [[ -n "${monitor_pid}" ]]; then
    kill -INT "${monitor_pid}" >/dev/null 2>&1 || true
    wait "${monitor_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${server_pid}" ]]; then
    kill -TERM "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  ip netns del "${netns}" >/dev/null 2>&1 || true
  ip link del "${server_if}" >/dev/null 2>&1 || true
  if [[ "${temporary_output}" -eq 1 ]]; then
    case "${output_dir}" in
      /tmp/vnet-grpc-stream-test.*)
        rm -rf -- "${output_dir}"
        ;;
      *)
        echo "grpc_stream_correlation_test: unsafe output path" >&2
        return 1
        ;;
    esac
  fi
}
trap cleanup EXIT

ip netns del "${netns}" >/dev/null 2>&1 || true
ip link del "${server_if}" >/dev/null 2>&1 || true
ip netns add "${netns}"
ip link add "${server_if}" type veth peer name "${client_if}"
ip link set "${client_if}" netns "${netns}"
ip addr add "${server_ip}/24" dev "${server_if}"
ip link set "${server_if}" up
ip netns exec "${netns}" ip addr add "${client_ip}/24" dev "${client_if}"
ip netns exec "${netns}" ip link set lo up
ip netns exec "${netns}" ip link set "${client_if}" up

python3 "${root_dir}/tests/grpc_h2_stream_replay.py" server \
  --address "${server_ip}" --port "${port}" \
  >"${output_dir}/server.log" 2>&1 &
server_pid=$!

"${root_dir}/build/grpc_monitor" --dev "${server_if}" --port "${port}" \
  --verbose-events >"${output_dir}/monitor.log" 2>&1 &
monitor_pid=$!

sleep 1
ip netns exec "${netns}" \
  python3 "${root_dir}/tests/grpc_h2_stream_replay.py" client \
    --address "${server_ip}" --port "${port}" \
    >"${output_dir}/client.log" 2>&1
wait "${server_pid}"
server_pid=""
sleep 2
kill -INT "${monitor_pid}"
wait "${monitor_pid}"
monitor_pid=""

for stream_id in 1 3 5; do
  grep -Eq "request stream_id=${stream_id} .*matched=0" \
    "${output_dir}/monitor.log"
  grep -Eq "request stream_id=${stream_id} .*h2_data=1 .*h2_end_stream=1" \
    "${output_dir}/monitor.log"
  grep -Eq "response stream_id=${stream_id} .*matched=1" \
    "${output_dir}/monitor.log"
done
grep -Eq 'grpc_metrics .*stream_aware=[1-9][0-9]* .*ringbuf_drop=0' \
  "${output_dir}/monitor.log"

echo "grpc_stream_correlation_test: PASS streams=1,3,5"
if [[ "${temporary_output}" -eq 0 ]]; then
  echo "Artifacts: ${output_dir}"
fi
