#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

for source_file in \
    "$root_dir/bpf/dns_monitor.c" \
    "$root_dir/bpf/dns_client_cache.c" \
    "$root_dir/bpf/grpc_monitor.c"; do
    if grep -q 'return TC_ACT_OK;' "$source_file"; then
        echo "observer terminates the TC classifier pipeline: $source_file" >&2
        exit 1
    fi
    grep -q 'return TC_ACT_PIPE;' "$source_file"
done
