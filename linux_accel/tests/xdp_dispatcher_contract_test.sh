#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test "$(rg -c '^SEC\("xdp"\)$' "${repo_dir}/bpf/xdp_dispatcher.c")" -eq 1
rg -q 'BPF_MAP_TYPE_PROG_ARRAY' "${repo_dir}/bpf/xdp_dispatcher.c"
rg -q 'bpf_tail_call' "${repo_dir}/bpf/xdp_dispatcher.c"
rg -q 'source_port == XDP_DISPATCH_DNS_PORT' \
  "${repo_dir}/bpf/xdp_dispatcher.c"
rg -q 'config->udp_slot' "${repo_dir}/bpf/xdp_dispatcher.c"
rg -q -- '--udp-policy-file' "${repo_dir}/src/dns_monitor_args.cpp"
rg -q 'xdp_attach_prog' "${repo_dir}/src/dns_monitor.cpp"
rg -q 'XDP_FLAGS_UPDATE_IF_NOEXIST' "${repo_dir}/src/dns_monitor.cpp"
rg -q 'install_udp_fastpath_entries' "${repo_dir}/src/dns_monitor.cpp"

clang -target bpf -D__BPF_TARGET__ -fsyntax-only \
  -I"${repo_dir}/third_party/bpf-headers" \
  -I"${repo_dir}/src/include" -I"${repo_dir}/bpf" \
  "${repo_dir}/bpf/xdp_dispatcher.c"

echo "XDP dispatcher contract tests passed"
