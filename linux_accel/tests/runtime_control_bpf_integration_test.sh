#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
controller="${1:-${root_dir}/build/dynamic_cache_controller}"
pin_root="/sys/fs/bpf/vnet-runtime-control-test-$$"
map_a="${pin_root}/endpoint_a"
map_b="${pin_root}/endpoint_b"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "runtime_control_bpf_integration_test: must run as root" >&2
  exit 1
fi

command -v bpftool >/dev/null
test -x "${controller}"
mkdir -p "${pin_root}"

cleanup() {
  case "${pin_root}" in
    /sys/fs/bpf/vnet-runtime-control-test-*)
      rm -rf -- "${pin_root}"
      ;;
    *)
      echo "runtime_control_bpf_integration_test: unsafe cleanup path" >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

create_map() {
  local path="$1"
  local name="$2"
  bpftool map create "${path}" type array key 4 value 16 entries 1 \
    name "${name}"
}

map_json() {
  bpftool -j map lookup pinned "$1" key hex 00 00 00 00 |
    tr -d '[:space:]"' |
    sed 's/0x//g'
}

expect_value() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(map_json "${path}")"
  case "${actual}" in
    *"value:[${expected}]"*)
      ;;
    *)
      echo "runtime_control_bpf_integration_test: unexpected ${path} value" >&2
      echo "${actual}" >&2
      exit 1
      ;;
  esac
}

create_map "${map_a}" rt_test_a
create_map "${map_b}" rt_test_b

printf '%s\n' \
  'timestamp_ms,dns_hits,dns_misses,dns_p95_us,grpc_hits,grpc_misses,grpc_p95_us,backend_qps,error_rate' \
  '100,70,30,1000,0,0,0,100,0' \
  '200,70,30,1000,0,0,0,100,0' \
  '300,70,30,1000,0,0,0,100,0' |
  "${controller}" \
    --control-map "${map_a}" \
    --control-map "${map_b}" \
    --window-size 2 \
    --required-windows 2 \
    --cooldown-ms 0 >/dev/null

# epoch=2, mode=SERVER_CACHE(2), flags=COMMITTED(1), little endian.
committed_server='02,00,00,00,00,00,00,00,02,00,00,00,01,00,00,00'
expect_value "${map_a}" "${committed_server}"
expect_value "${map_b}" "${committed_server}"

# Seed a known committed DUAL_CACHE state, then freeze endpoint B so the
# publisher fails after staging endpoint A. Endpoint A must be rolled back.
dual_epoch_nine=(
  09 00 00 00 00 00 00 00
  04 00 00 00
  01 00 00 00
)
bpftool map update pinned "${map_a}" key hex 00 00 00 00 \
  value hex "${dual_epoch_nine[@]}"
bpftool map update pinned "${map_b}" key hex 00 00 00 00 \
  value hex "${dual_epoch_nine[@]}"
bpftool map freeze pinned "${map_b}"

if "${controller}" \
  --control-map "${map_a}" \
  --control-map "${map_b}" </dev/null >/dev/null 2>&1; then
  echo "runtime_control_bpf_integration_test: injected failure succeeded" >&2
  exit 1
fi

committed_dual='09,00,00,00,00,00,00,00,04,00,00,00,01,00,00,00'
expect_value "${map_a}" "${committed_dual}"
expect_value "${map_b}" "${committed_dual}"

echo "runtime_control_bpf_integration_test: PASS"
