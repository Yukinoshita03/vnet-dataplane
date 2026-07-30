#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dns_monitor="${root_dir}/build/dns_monitor"
grpc_monitor="${root_dir}/build/grpc_monitor"
dns_tc_bpf="${root_dir}/build/dns_monitor.bpf.o"
dns_xdp_bpf="${root_dir}/build/dns_xdp_monitor.bpf.o"
dns_client_bpf="${root_dir}/build/dns_client_cache.bpf.o"
grpc_bpf="${root_dir}/build/grpc_monitor.bpf.o"
tag="$$"
host_if="vho${tag}"
peer_if="vhp${tag}"
temporary_output=0
if [[ -n "${OUT_DIR:-}" ]]; then
    temp_dir="${OUT_DIR}"
    mkdir -p "${temp_dir}"
else
    temp_dir="$(mktemp -d /tmp/vnet-hook-ownership.XXXXXX)"
    temporary_output=1
fi
monitor_pid=""

if [[ "$(id -u)" -ne 0 ]]; then
    echo "hook_ownership_regression_test: must run as root" >&2
    exit 1
fi

for command in ip tc python3; do
    command -v "${command}" >/dev/null
done
for file in "${dns_monitor}" "${grpc_monitor}" "${dns_tc_bpf}" \
    "${dns_xdp_bpf}" "${dns_client_bpf}" "${grpc_bpf}"; do
    test -e "${file}"
done

cleanup_monitor() {
    if [[ -z "${monitor_pid}" ]]; then
        return 0
    fi
    kill -INT "${monitor_pid}" >/dev/null 2>&1 || true
    wait "${monitor_pid}" >/dev/null 2>&1 || true
    monitor_pid=""
}

cleanup() {
    local status=$?
    cleanup_monitor
    ip link del dev "${host_if}" >/dev/null 2>&1 || true
    if [[ "${temporary_output}" -eq 1 && "${status}" -eq 0 ]]; then
        case "${temp_dir}" in
            /tmp/vnet-hook-ownership.*)
                rm -rf -- "${temp_dir}"
                ;;
            *)
                echo "hook_ownership_regression_test: unsafe temp cleanup" >&2
                return 1
                ;;
        esac
    else
        echo "hook_ownership_regression_test artifacts: ${temp_dir}" >&2
    fi
    return "${status}"
}
trap cleanup EXIT

wait_for_tc_handle() {
    local direction=$1
    local handle=$2
    for _ in $(seq 1 50); do
        tc filter show dev "${host_if}" "${direction}" |
            grep -q "handle ${handle} " && return 0
        sleep 0.1
    done
    tc filter show dev "${host_if}" "${direction}" >&2 || true
    return 1
}

wait_for_xdp() {
    for _ in $(seq 1 50); do
        xdp_snapshot | grep -q '"prog"' && return 0
        sleep 0.1
    done
    ip -d link show dev "${host_if}" >&2 || true
    return 1
}

xdp_snapshot() {
    ip -d -j link show dev "${host_if}" |
        python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0].get("xdp", {}), sort_keys=True))'
}

assert_tc_handle() {
    local direction=$1
    local handle=$2
    tc filter show dev "${host_if}" "${direction}" |
        grep -q "handle ${handle} "
}

assert_no_tc_handle() {
    local direction=$1
    local handle=$2
    if tc filter show dev "${host_if}" "${direction}" |
        grep -q "handle ${handle} "; then
        echo "unexpected TC ${direction} handle ${handle} remains" >&2
        return 1
    fi
}

add_external_tc() {
    local direction=$1
    local handle=$2
    tc filter add dev "${host_if}" "${direction}" protocol all pref 1 \
        handle "${handle}" bpf da obj "${dns_tc_bpf}" \
        sec "tc/${direction}"
}

ip link add "${host_if}" type veth peer name "${peer_if}"
ip link set "${host_if}" up
ip link set "${peer_if}" up

# A pre-existing foreign pipeline and generic XDP hook must be left unchanged.
tc qdisc add dev "${host_if}" clsact
add_external_tc ingress 0x65
add_external_tc egress 0x66
ip link set dev "${host_if}" xdpgeneric obj "${dns_xdp_bpf}" sec xdp
foreign_xdp_before="$(xdp_snapshot)"

"${dns_monitor}" --dev "${host_if}" --hook tc \
    --bpf-object "${dns_tc_bpf}" >"${temp_dir}/dns-tc.log" 2>&1 &
monitor_pid=$!
wait_for_tc_handle ingress 0x1
wait_for_tc_handle egress 0x1
cleanup_monitor
assert_no_tc_handle ingress 0x1
assert_no_tc_handle egress 0x1

"${grpc_monitor}" --dev "${host_if}" --port 50051 \
    --bpf-object "${grpc_bpf}" >"${temp_dir}/grpc-tc.log" 2>&1 &
monitor_pid=$!
wait_for_tc_handle ingress 0x2
wait_for_tc_handle egress 0x2
cleanup_monitor
assert_no_tc_handle ingress 0x2
assert_no_tc_handle egress 0x2

if "${dns_monitor}" --dev "${host_if}" --hook xdp --role client \
    --xdp-mode generic --trusted-dns 192.0.2.53 \
    --bpf-object "${dns_client_bpf}" >"${temp_dir}/dns-xdp-collision.log" 2>&1; then
    echo "DNS client unexpectedly replaced a foreign XDP program" >&2
    exit 1
fi
grep -q "Failed to attach client XDP program" \
    "${temp_dir}/dns-xdp-collision.log"
assert_tc_handle ingress 0x65
assert_tc_handle egress 0x66
[[ "$(xdp_snapshot)" == "${foreign_xdp_before}" ]]

# If foreign filters join a clsact created by DNS, monitor cleanup must keep them.
ip link set dev "${host_if}" xdpgeneric off
tc qdisc del dev "${host_if}" clsact
"${dns_monitor}" --dev "${host_if}" --hook tc \
    --bpf-object "${dns_tc_bpf}" >"${temp_dir}/dns-tc-late-join.log" 2>&1 &
monitor_pid=$!
wait_for_tc_handle ingress 0x1
wait_for_tc_handle egress 0x1
add_external_tc ingress 0x65
add_external_tc egress 0x66
cleanup_monitor
assert_tc_handle ingress 0x65
assert_tc_handle egress 0x66
assert_no_tc_handle ingress 0x1
assert_no_tc_handle egress 0x1

# A monitor that owns the only XDP hook must remove it on a normal exit.
tc qdisc del dev "${host_if}" clsact
"${dns_monitor}" --dev "${host_if}" --hook xdp --role server \
    --xdp-mode generic --bpf-object "${dns_xdp_bpf}" \
    --cache-domain ownership.test --cache-ip 10.0.0.7 --cache-ttl 60 \
    >"${temp_dir}/dns-xdp-normal-cleanup.log" 2>&1 &
monitor_pid=$!
wait_for_xdp
cleanup_monitor
[[ "$(xdp_snapshot)" == "{}" ]]

# Replacing both DNS TC slots with foreign programs must preserve both of them.
"${dns_monitor}" --dev "${host_if}" --hook tc \
    --bpf-object "${dns_tc_bpf}" >"${temp_dir}/dns-tc-replace.log" 2>&1 &
monitor_pid=$!
wait_for_tc_handle ingress 0x1
wait_for_tc_handle egress 0x1
tc filter del dev "${host_if}" ingress pref 1 handle 0x1 bpf
tc filter add dev "${host_if}" ingress protocol all pref 1 handle 0x1 \
    bpf da obj "${dns_tc_bpf}" sec tc/ingress
tc filter del dev "${host_if}" egress pref 1 handle 0x1 bpf
tc filter add dev "${host_if}" egress protocol all pref 1 handle 0x1 \
    bpf da obj "${dns_tc_bpf}" sec tc/egress
cleanup_monitor
assert_tc_handle ingress 0x1
assert_tc_handle egress 0x1
grep -q "Refusing to detach ingress tc program because ownership changed" \
    "${temp_dir}/dns-tc-replace.log"
grep -q "Refusing to detach egress tc program because ownership changed" \
    "${temp_dir}/dns-tc-replace.log"

# Replacing a running DNS XDP hook with a foreign program must survive cleanup.
tc qdisc del dev "${host_if}" clsact >/dev/null 2>&1 || true
"${dns_monitor}" --dev "${host_if}" --hook xdp --role server \
    --xdp-mode generic --bpf-object "${dns_xdp_bpf}" \
    --cache-domain ownership.test --cache-ip 10.0.0.7 --cache-ttl 60 \
    >"${temp_dir}/dns-xdp-replace.log" 2>&1 &
monitor_pid=$!
wait_for_xdp
ip link set dev "${host_if}" xdpgeneric off
ip link set dev "${host_if}" xdpgeneric obj "${dns_xdp_bpf}" sec xdp
foreign_xdp_after_replace="$(xdp_snapshot)"
cleanup_monitor
[[ "$(xdp_snapshot)" == "${foreign_xdp_after_replace}" ]]
grep -q "Refusing to detach XDP program because ownership changed" \
    "${temp_dir}/dns-xdp-replace.log"

# Replacing both gRPC TC slots with foreign programs must preserve both of them.
ip link set dev "${host_if}" xdpgeneric off
tc qdisc del dev "${host_if}" clsact >/dev/null 2>&1 || true
"${grpc_monitor}" --dev "${host_if}" --port 50051 \
    --bpf-object "${grpc_bpf}" >"${temp_dir}/grpc-tc-replace.log" 2>&1 &
monitor_pid=$!
wait_for_tc_handle ingress 0x2
wait_for_tc_handle egress 0x2
tc filter del dev "${host_if}" ingress pref 1 handle 0x2 bpf
tc filter add dev "${host_if}" ingress protocol all pref 1 handle 0x2 \
    bpf da obj "${grpc_bpf}" sec tc/ingress
tc filter del dev "${host_if}" egress pref 1 handle 0x2 bpf
tc filter add dev "${host_if}" egress protocol all pref 1 handle 0x2 \
    bpf da obj "${grpc_bpf}" sec tc/egress
cleanup_monitor
assert_tc_handle ingress 0x2
assert_tc_handle egress 0x2
grep -q "Refusing to detach ingress tc program because ownership changed" \
    "${temp_dir}/grpc-tc-replace.log"
grep -q "Refusing to detach egress tc program because ownership changed" \
    "${temp_dir}/grpc-tc-replace.log"

echo "hook_ownership_regression_test: PASS"
