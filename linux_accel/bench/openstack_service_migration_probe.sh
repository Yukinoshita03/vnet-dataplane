#!/usr/bin/env bash
set -euo pipefail

out_dir=${OUT_DIR:?OUT_DIR is required}
backend_id=${BACKEND_ID:?BACKEND_ID is required}
client_ip=${CLIENT_IP:?CLIENT_IP is required}
backend_ip=${BACKEND_IP:?BACKEND_IP is required}
guest_key=${GUEST_KEY:?GUEST_KEY is required}
dns_monitor=${DNS_MONITOR:?DNS_MONITOR is required}
dns_bpf=${DNS_BPF:?DNS_BPF is required}
dns_harness=${DNS_HARNESS:?DNS_HARNESS is required}
grpc_harness=${GRPC_HARNESS:?GRPC_HARNESS is required}
grpc_cache=${GRPC_CACHE:?GRPC_CACHE is required}
cachectl=${CACHECTL:?CACHECTL is required}
migration_runner=${MIGRATION_RUNNER:?MIGRATION_RUNNER is required}
reset_runner=${RESET_RUNNER:?RESET_RUNNER is required}
host_metrics=${HOST_METRICS:?HOST_METRICS is required}

netns=${NETNS:-codex-campaign-probe}
guest_user=${GUEST_USER:-ubuntu}
sudo_password=${SUDO_PASS:-}
source_host=${SOURCE_HOST:-master}
target_host=${TARGET_HOST:-compute2}
probe_iterations=${PROBE_ITERATIONS:-300}
probe_pause=${PROBE_PAUSE:-0.2}
domain=${DOMAIN:-example.test}
answer_ip=${ANSWER_IP:-10.0.0.123}
payload=${PAYLOAD:-demo}
method=/grpc.health.v1.Health/Check
pin_dir=/sys/fs/bpf/vnet-migration-grpc
askpass=/tmp/vnet-migration-askpass-$$
forward_completed=0

mkdir -p "$out_dir"
exec > >(tee "$out_dir/run.log") 2>&1
if [[ -n "$sudo_password" ]]; then
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$SUDO_PASS"' > "$askpass"
    chmod 700 "$askpass"
fi

sudo_cmd() {
    if [[ -n "$sudo_password" ]]; then
        printf '%s\n' "$sudo_password" | sudo -S -p '' "$@"
    else
        sudo "$@"
    fi
}

sudo_stream_cmd() {
    if [[ -n "$sudo_password" ]]; then
        SUDO_PASS="$sudo_password" SUDO_ASKPASS="$askpass" sudo -A "$@"
    else
        sudo "$@"
    fi
}

ssh_opts=(-i "$guest_key" -o BatchMode=yes -o ConnectTimeout=8
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

guest_cmd() {
    local ip=$1
    local command=$2
    local encoded
    encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
    sudo_cmd ip netns exec "$netns" ssh "${ssh_opts[@]}" "$guest_user@$ip" \
        "echo $encoded | base64 -d | bash"
}

copy_guest() {
    local ip=$1
    local source_file=$2
    local target_file=$3
    gzip -1c "$source_file" | base64 | tr -d '\n' |
        sudo_stream_cmd ip netns exec "$netns" ssh "${ssh_opts[@]}" \
            "$guest_user@$ip" \
            "base64 -d | gzip -d > '$target_file' && chmod +x '$target_file'"
}

server_host() {
    openstack server show "$backend_id" \
        -f value -c OS-EXT-SRV-ATTR:hypervisor_hostname
}

stop_probes() {
    guest_cmd "$client_ip" \
        'for pid_file in /tmp/vnet-mig-dns.pid /tmp/vnet-mig-grpc.pid; do if test -s "$pid_file"; then kill "$(cat "$pid_file")" 2>/dev/null || true; fi; done'
}

collect_probe_logs() {
    guest_cmd "$client_ip" 'cat /tmp/vnet-mig-dns.log 2>/dev/null || true' \
        > "$out_dir/dns-probe.log" || true
    guest_cmd "$client_ip" 'cat /tmp/vnet-mig-grpc.log 2>/dev/null || true' \
        > "$out_dir/grpc-probe.log" || true
}

cleanup_guests() {
    stop_probes
    guest_cmd "$backend_ip" \
        'sudo -n killall -q dns_monitor openstack_grpc_harness grpc_fast_cache 2>/dev/null || true; sudo -n rm -rf /sys/fs/bpf/vnet-migration-grpc; rm -f /tmp/dns_monitor /tmp/dns_xdp_monitor.bpf.o /tmp/openstack_grpc_harness /tmp/grpc_fast_cache /tmp/cachectl /tmp/vnet-migration-policy.txt'
    guest_cmd "$client_ip" \
        'rm -f /tmp/openstack_dns_harness /tmp/openstack_grpc_harness /tmp/vnet-mig-dns.pid /tmp/vnet-mig-grpc.pid /tmp/vnet-mig-dns.log /tmp/vnet-mig-grpc.log'
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    stop_probes
    collect_probe_logs
    current_host=$(server_host 2>/dev/null)
    if [[ "$current_host" == "$target_host" ]]; then
        bash "$reset_runner" --vm-id "$backend_id" \
            --expected-source "$target_host" --target-host "$source_host" \
            --run-dir "$out_dir/reset-from-trap" --disk-overcommit \
            --timeout-seconds 900 --poll-seconds 5
    fi
    cleanup_guests
    rm -f "$askpass"
    printf 'cleanup_status=%s\n' "$status" > "$out_dir/cleanup-status.txt"
    exit "$status"
}
trap cleanup EXIT

set +u
source /opt/stack/devstack/openrc admin admin >/dev/null
set -u
before_host=$(server_host)
[[ "$before_host" == "$source_host" ]] || {
    echo "backend must start on $source_host, got $before_host" >&2
    exit 1
}

for item in "$dns_monitor" "$dns_bpf" "$dns_harness" "$grpc_harness" \
    "$grpc_cache" "$cachectl" "$migration_runner" "$reset_runner" \
    "$host_metrics"; do
    [[ -r "$item" ]] || { echo "missing migration input: $item" >&2; exit 1; }
done

copy_guest "$client_ip" "$dns_harness" /tmp/openstack_dns_harness
copy_guest "$client_ip" "$grpc_harness" /tmp/openstack_grpc_harness
copy_guest "$backend_ip" "$dns_monitor" /tmp/dns_monitor
copy_guest "$backend_ip" "$dns_bpf" /tmp/dns_xdp_monitor.bpf.o
copy_guest "$backend_ip" "$grpc_harness" /tmp/openstack_grpc_harness
copy_guest "$backend_ip" "$grpc_cache" /tmp/grpc_fast_cache
copy_guest "$backend_ip" "$cachectl" /tmp/cachectl

guest_cmd "$backend_ip" \
    "sudo -n killall -q dns_monitor openstack_grpc_harness grpc_fast_cache 2>/dev/null || true
sudo -n mkdir -p /sys/fs/bpf
mountpoint -q /sys/fs/bpf || sudo -n mount -t bpf bpf /sys/fs/bpf
sudo -n rm -rf $pin_dir
sudo -n mkdir -p $pin_dir
nohup sudo -n /tmp/dns_monitor --dev ens3 --hook xdp --role server --xdp-mode generic --bpf-object /tmp/dns_xdp_monitor.bpf.o --cache-domain '$domain' --cache-ip '$answer_ip' --cache-ttl 600 --verbose-events >/tmp/vnet-migration-dns.log 2>&1 </dev/null &
nohup sudo -n /tmp/openstack_grpc_harness server '$backend_ip' 50051 300 >/tmp/vnet-migration-grpc-backend.log 2>&1 </dev/null &
sudo -n /tmp/openstack_grpc_harness seed $pin_dir/grpc_policy_map
sudo -n /tmp/openstack_grpc_harness seed-response $pin_dir/grpc_response_cache '$payload' SERVING 600
cat >/tmp/vnet-migration-policy.txt <<EOF
grpc $method 600 idempotent
grpc-cache $method $payload SERVING 600
EOF
sudo -n /tmp/cachectl --policy-file /tmp/vnet-migration-policy.txt --grpc-map $pin_dir/grpc_policy_map --grpc-response-map $pin_dir/grpc_response_cache --replace
nohup sudo -n /tmp/grpc_fast_cache --grpc-map $pin_dir/grpc_policy_map --grpc-response-map $pin_dir/grpc_response_cache --listen '$backend_ip':50052 --backend '$backend_ip':50051 --method '$method' --verbose >/tmp/vnet-migration-grpc-cache.log 2>&1 </dev/null &"
sleep 3

guest_cmd "$backend_ip" \
    "hostname
sudo -n bpftool net show dev ens3
sudo -n bpftool map show pinned $pin_dir/grpc_response_cache
ss -lunp | grep ':53 ' || true
ss -ltnp | grep -E ':5005[12] ' || true" > "$out_dir/backend-before.txt"

guest_cmd "$client_ip" \
    "rm -f /tmp/vnet-mig-dns.log /tmp/vnet-mig-grpc.log
nohup bash -c 'for i in \$(seq 1 $probe_iterations); do printf \"ts_ms=%s \" \"\$(date +%s%3N)\"; /tmp/openstack_dns_harness client \"$backend_ip\" 53 \"$domain\" \"$answer_ip\" 20 0; sleep \"$probe_pause\"; done' >/tmp/vnet-mig-dns.log 2>&1 </dev/null & echo \$! >/tmp/vnet-mig-dns.pid
nohup bash -c 'for i in \$(seq 1 $probe_iterations); do printf \"ts_ms=%s \" \"\$(date +%s%3N)\"; /tmp/openstack_grpc_harness client \"$backend_ip\" 50052 20 0 \"$payload\"; sleep \"$probe_pause\"; done' >/tmp/vnet-mig-grpc.log 2>&1 </dev/null & echo \$! >/tmp/vnet-mig-grpc.pid"
sleep 5

bash "$migration_runner" --execute --block-migration --skip-shaping \
    --run-dir "$out_dir/forward" --vm-id "$backend_id" \
    --target-host "$target_host" --iface ens33 \
    --host-metrics "$host_metrics" \
    --traffic-external --policy resource-only --poll-seconds 2 --max-polls 300
forward_completed=1

[[ "$(server_host)" == "$target_host" ]]
sleep 8
stop_probes
collect_probe_logs
guest_cmd "$backend_ip" \
    "hostname
sudo -n bpftool net show dev ens3
sudo -n bpftool map show pinned $pin_dir/grpc_response_cache
ss -lunp | grep ':53 ' || true
ss -ltnp | grep -E ':5005[12] ' || true" > "$out_dir/backend-after-forward.txt"

bash "$reset_runner" --vm-id "$backend_id" --expected-source "$target_host" \
    --target-host "$source_host" --run-dir "$out_dir/reset" \
    --disk-overcommit --timeout-seconds 900 --poll-seconds 5
[[ "$(server_host)" == "$source_host" ]]

dns_total=$(grep -c 'ts_ms=' "$out_dir/dns-probe.log" || true)
dns_failed=$(grep 'ts_ms=' "$out_dir/dns-probe.log" |
    grep -E -c 'failed=[1-9]|success=0' || true)
grpc_total=$(grep -c 'ts_ms=' "$out_dir/grpc-probe.log" || true)
grpc_failed=$(grep 'ts_ms=' "$out_dir/grpc-probe.log" |
    grep -E -c 'failed=[1-9]|count=0' || true)
{
    printf 'forward_completed=%s\n' "$forward_completed"
    printf 'dns_batches=%s\n' "$dns_total"
    printf 'dns_failed_batches=%s\n' "$dns_failed"
    printf 'grpc_batches=%s\n' "$grpc_total"
    printf 'grpc_failed_batches=%s\n' "$grpc_failed"
    printf 'final_host=%s\n' "$(server_host)"
} > "$out_dir/summary.txt"
cat "$out_dir/summary.txt"
