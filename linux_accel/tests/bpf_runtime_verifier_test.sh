#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin_root="/sys/fs/bpf/vnet-runtime-verifier-test-$$"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "bpf_runtime_verifier_test: must run as root" >&2
  exit 1
fi

command -v bpftool >/dev/null

cleanup() {
  case "${pin_root}" in
    /sys/fs/bpf/vnet-runtime-verifier-test-*)
      rm -rf -- "${pin_root}"
      ;;
    *)
      echo "bpf_runtime_verifier_test: unsafe cleanup path" >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

mkdir -p "${pin_root}"
bpftool prog loadall "${root_dir}/build/dns_xdp_monitor.bpf.o" \
  "${pin_root}/dns-server"
bpftool prog loadall "${root_dir}/build/dns_client_cache.bpf.o" \
  "${pin_root}/dns-client"
bpftool prog loadall "${root_dir}/build/grpc_monitor.bpf.o" \
  "${pin_root}/grpc"

test -e "${pin_root}/dns-server/dns_xdp_monitor"
test -e "${pin_root}/dns-client/dns_client_cache_xdp"
test -e "${pin_root}/dns-client/dns_client_cache_egress"
test -e "${pin_root}/grpc/grpc_ingress"
test -e "${pin_root}/grpc/grpc_egress"

echo "bpf_runtime_verifier_test: PASS"
