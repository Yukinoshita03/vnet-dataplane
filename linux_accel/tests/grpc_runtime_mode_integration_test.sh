#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
controller="${root_dir}/build/dynamic_cache_controller"
fast_cache="${root_dir}/build/grpc_fast_cache"
harness="${root_dir}/build/openstack_grpc_harness"
pin_root="/sys/fs/bpf/vnet-grpc-runtime-test-$$"
policy_map="${pin_root}/grpc_policy_map"
response_map="${pin_root}/grpc_response_cache"
runtime_map="${pin_root}/cache_runtime_control"
backend_port=$((52000 + $$ % 1000))
server_cache_port=$((backend_port + 1))
client_cache_port=$((backend_port + 2))
payload="00"
temp_dir="$(mktemp -d /tmp/vnet-grpc-runtime-test.XXXXXX)"
backend_pid=""
server_cache_pid=""
client_cache_pid=""

if [[ "$(id -u)" -ne 0 ]]; then
  echo "grpc_runtime_mode_integration_test: must run as root" >&2
  exit 1
fi

command -v bpftool >/dev/null
for file in "${controller}" "${fast_cache}" "${harness}"; do
  test -x "${file}"
done

stop_process() {
  local pid="$1"
  if [[ -n "${pid}" ]]; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    for _ in {1..50}; do
      kill -0 "${pid}" >/dev/null 2>&1 || break
      sleep 0.02
    done
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  stop_process "${client_cache_pid}"
  stop_process "${server_cache_pid}"
  stop_process "${backend_pid}"
  case "${pin_root}" in
    /sys/fs/bpf/vnet-grpc-runtime-test-*)
      rm -rf -- "${pin_root}"
      ;;
    *)
      echo "grpc_runtime_mode_integration_test: unsafe cleanup path" >&2
      return 1
      ;;
  esac
  case "${temp_dir}" in
    /tmp/vnet-grpc-runtime-test.*)
      rm -rf -- "${temp_dir}"
      ;;
    *)
      echo "grpc_runtime_mode_integration_test: unsafe temp cleanup" >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

mkdir -p "${pin_root}"
"${harness}" seed "${policy_map}" >/dev/null
"${harness}" seed-response "${response_map}" "${payload}" SERVING 120 >/dev/null
bpftool map create "${runtime_map}" type array key 4 value 16 entries 1 \
  name grpc_rt_test

publish_mode() {
  "${controller}" --control-map "${runtime_map}" \
    --initial-mode "$1" </dev/null >/dev/null
}

expect_success() {
  local port="$1"
  "${harness}" client 127.0.0.1 "${port}" 1 0 "${payload}" >/dev/null
}

expect_failure() {
  local port="$1"
  if "${harness}" client 127.0.0.1 "${port}" 1 0 "${payload}" \
    >/dev/null 2>&1; then
    echo "grpc_runtime_mode_integration_test: request unexpectedly succeeded" >&2
    exit 1
  fi
}

"${harness}" server 127.0.0.1 "${backend_port}" 0 \
  >"${temp_dir}/backend.log" 2>&1 &
backend_pid=$!
"${fast_cache}" --grpc-map "${policy_map}" \
  --grpc-response-map "${response_map}" \
  --runtime-control-map "${runtime_map}" --cache-role server \
  --listen "127.0.0.1:${server_cache_port}" \
  --backend "127.0.0.1:${backend_port}" \
  --method /grpc.health.v1.Health/Check \
  --verbose \
  >"${temp_dir}/server-cache.log" 2>&1 &
server_cache_pid=$!
sleep 0.2

publish_mode bypass
expect_success "${server_cache_port}"
grep -Eq 'shadow_hit=[1-9][0-9]*' "${temp_dir}/server-cache.log"
stop_process "${backend_pid}"
backend_pid=""
publish_mode server
expect_success "${server_cache_port}"
publish_mode client
expect_failure "${server_cache_port}"
publish_mode dual
expect_success "${server_cache_port}"

"${fast_cache}" --grpc-map "${policy_map}" \
  --grpc-response-map "${response_map}" \
  --runtime-control-map "${runtime_map}" --cache-role client \
  --listen "127.0.0.1:${client_cache_port}" \
  --backend "127.0.0.1:${backend_port}" \
  --method /grpc.health.v1.Health/Check \
  --verbose \
  >"${temp_dir}/client-cache.log" 2>&1 &
client_cache_pid=$!
sleep 0.2

publish_mode server
expect_failure "${client_cache_port}"
grep -Eq 'shadow_hit=[1-9][0-9]*' "${temp_dir}/client-cache.log"
publish_mode client
expect_success "${client_cache_port}"
publish_mode dual
expect_success "${client_cache_port}"
publish_mode bypass
expect_failure "${client_cache_port}"

echo "grpc_runtime_mode_integration_test: PASS"
