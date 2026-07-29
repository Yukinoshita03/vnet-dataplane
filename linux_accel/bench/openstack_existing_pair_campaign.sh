#!/usr/bin/env bash
set -euo pipefail

accel_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out_dir=${OUT_DIR:?OUT_DIR is required}
client_ip=${CLIENT_IP:?CLIENT_IP is required}
backend_ip=${BACKEND_IP:?BACKEND_IP is required}
client_tap=${CLIENT_TAP:?CLIENT_TAP is required}
netns=${NETNS:-codex-campaign-probe}
guest_key=${GUEST_KEY:?GUEST_KEY is required}
guest_user=${GUEST_USER:-ubuntu}
sudo_password=${SUDO_PASS:-}
rounds=${ROUNDS:-5}
requests=${REQUESTS:-1000}
warmup=${WARMUP:-100}
payload=${PAYLOAD:-demo}
domain=${DOMAIN:-example.test}
answer_ip=${ANSWER_IP:-10.0.0.123}
method=/grpc.health.v1.Health/Check

dns_harness=${DNS_HARNESS:?DNS_HARNESS is required}
grpc_harness=${GRPC_HARNESS:?GRPC_HARNESS is required}
grpc_cache=${GRPC_CACHE:?GRPC_CACHE is required}
cachectl=${CACHECTL:?CACHECTL is required}

dns_monitor=$accel_dir/build/dns_monitor
dns_bpf=$accel_dir/build/dns_client_cache.bpf.o
grpc_monitor=$accel_dir/build/grpc_monitor
grpc_bpf=$accel_dir/build/grpc_monitor.bpf.o

dns_pid=
grpc_pid=
pin_dir=/sys/fs/bpf/vnet-five-experiments-grpc
sudo_askpass=/tmp/vnet-five-experiments-askpass-$$
mkdir -p "$out_dir"
exec > >(tee "$out_dir/run.log") 2>&1
if [[ -n "$sudo_password" ]]; then
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$SUDO_PASS"' > "$sudo_askpass"
    chmod 700 "$sudo_askpass"
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
        SUDO_PASS="$sudo_password" SUDO_ASKPASS="$sudo_askpass" sudo -A "$@"
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
        sudo_stream_cmd ip netns exec "$netns" ssh "${ssh_opts[@]}" "$guest_user@$ip" \
            "base64 -d | gzip -d > '$target_file' && chmod +x '$target_file'"
}

field() {
    tr ' ' '\n' <<<"$1" | awk -F= -v wanted="$2" \
        '$1 == wanted {print $2; exit}'
}

stop_monitors() {
    if [[ -n "$dns_pid" ]]; then
        sudo_cmd kill -TERM "$dns_pid" >/dev/null 2>&1 || true
        dns_pid=
    fi
    if [[ -n "$grpc_pid" ]]; then
        sudo_cmd kill -TERM "$grpc_pid" >/dev/null 2>&1 || true
        grpc_pid=
    fi
    sleep 1
    sudo_cmd tc filter del dev "$client_tap" ingress pref 1 handle 1 bpf \
        >/dev/null 2>&1 || true
    sudo_cmd tc filter del dev "$client_tap" egress pref 1 handle 1 bpf \
        >/dev/null 2>&1 || true
    sudo_cmd tc filter del dev "$client_tap" ingress pref 1 handle 2 bpf \
        >/dev/null 2>&1 || true
    sudo_cmd tc filter del dev "$client_tap" egress pref 1 handle 2 bpf \
        >/dev/null 2>&1 || true
    sudo_cmd ip link set dev "$client_tap" xdp off >/dev/null 2>&1 || true
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    stop_monitors
    guest_cmd "$client_ip" \
        'sudo -n killall -q openstack_dns_harness openstack_grpc_harness 2>/dev/null || true; rm -f /tmp/openstack_dns_harness /tmp/openstack_grpc_harness'
    guest_cmd "$backend_ip" \
        'sudo -n killall -q openstack_dns_harness openstack_grpc_harness grpc_fast_cache 2>/dev/null || true; sudo -n rm -rf /sys/fs/bpf/vnet-five-experiments-grpc; rm -f /tmp/openstack_dns_harness /tmp/openstack_grpc_harness /tmp/grpc_fast_cache /tmp/cachectl /tmp/vnet-grpc-policy.txt /tmp/vnet-grpc-dynamic.txt'
    rm -f "$sudo_askpass"
    printf 'cleanup_status=%s\n' "$status" > "$out_dir/cleanup-status.txt"
    exit "$status"
}
trap cleanup EXIT

verify_tc_order() {
    local label=$1
    local ingress="$out_dir/$label.tc-ingress.txt"
    local egress="$out_dir/$label.tc-egress.txt"
    sudo_cmd tc filter show dev "$client_tap" ingress > "$ingress"
    sudo_cmd tc filter show dev "$client_tap" egress > "$egress"
    awk '
        /handle 0x1 / {dns=NR}
        /handle 0x2 / {grpc=NR}
        /handle 0x65 / {netmig=NR}
        END {exit !(dns && grpc && netmig && dns < netmig && grpc < netmig)}
    ' "$ingress"
    awk '
        /handle 0x1 / {dns=NR}
        /handle 0x2 / {grpc=NR}
        /handle 0x66 / {netmig=NR}
        END {exit !(dns && grpc && netmig && dns < netmig && grpc < netmig)}
    ' "$egress"
}

start_dns_monitor() {
    local label=$1
    dns_pid=$(sudo_cmd bash -c \
        "setsid '$dns_monitor' --dev '$client_tap' --hook xdp --role client --xdp-mode generic --bpf-object '$dns_bpf' --trusted-dns '$backend_ip' --verbose-events >'$out_dir/$label.dns-monitor.log' 2>&1 </dev/null & echo \$!")
    sleep 2
}

start_grpc_monitor() {
    local label=$1
    grpc_pid=$(sudo_cmd bash -c \
        "setsid '$grpc_monitor' --dev '$client_tap' --bpf-object '$grpc_bpf' --port 50052 --verbose-events >'$out_dir/$label.grpc-monitor.log' 2>&1 </dev/null & echo \$!")
    sleep 2
}

install_status() {
    local status=$1
    guest_cmd "$backend_ip" \
        "cat >/tmp/vnet-grpc-dynamic.txt <<EOF
grpc-cache $method $payload $status 600
EOF
sudo -n /tmp/cachectl --policy-file /tmp/vnet-grpc-dynamic.txt --grpc-response-map $pin_dir/grpc_response_cache --replace"
}

for file in "$dns_harness" "$grpc_harness" "$grpc_cache" "$cachectl" \
    "$dns_monitor" "$dns_bpf" "$grpc_monitor" "$grpc_bpf"; do
    [[ -x "$file" || -r "$file" ]] || {
        echo "missing campaign input: $file" >&2
        exit 1
    }
done

copy_guest "$client_ip" "$dns_harness" /tmp/openstack_dns_harness
copy_guest "$client_ip" "$grpc_harness" /tmp/openstack_grpc_harness
copy_guest "$backend_ip" "$dns_harness" /tmp/openstack_dns_harness
copy_guest "$backend_ip" "$grpc_harness" /tmp/openstack_grpc_harness
copy_guest "$backend_ip" "$grpc_cache" /tmp/grpc_fast_cache
copy_guest "$backend_ip" "$cachectl" /tmp/cachectl

guest_cmd "$backend_ip" \
    "sudo -n killall -q openstack_dns_harness openstack_grpc_harness grpc_fast_cache 2>/dev/null || true
sudo -n mkdir -p /sys/fs/bpf
mountpoint -q /sys/fs/bpf || sudo -n mount -t bpf bpf /sys/fs/bpf
sudo -n rm -rf $pin_dir
sudo -n mkdir -p $pin_dir
nohup sudo -n /tmp/openstack_dns_harness server 0.0.0.0 53 '$domain' '$answer_ip' 60 /tmp/vnet-dns-backend-count >/tmp/vnet-dns-backend.log 2>&1 </dev/null &
nohup sudo -n /tmp/openstack_grpc_harness server '$backend_ip' 50051 300 >/tmp/vnet-grpc-backend.log 2>&1 </dev/null &
sudo -n /tmp/openstack_grpc_harness seed $pin_dir/grpc_policy_map
sudo -n /tmp/openstack_grpc_harness seed-response $pin_dir/grpc_response_cache '$payload' SERVING 600
cat >/tmp/vnet-grpc-policy.txt <<EOF
grpc $method 600 idempotent
grpc-cache $method $payload SERVING 600
EOF
sudo -n /tmp/cachectl --policy-file /tmp/vnet-grpc-policy.txt --grpc-map $pin_dir/grpc_policy_map --grpc-response-map $pin_dir/grpc_response_cache --replace
nohup sudo -n /tmp/grpc_fast_cache --grpc-map $pin_dir/grpc_policy_map --grpc-response-map $pin_dir/grpc_response_cache --listen '$backend_ip':50052 --backend '$backend_ip':50051 --method '$method' --verbose >/tmp/vnet-grpc-cache.log 2>&1 </dev/null &"
sleep 2
guest_cmd "$backend_ip" \
    "ps -ef | grep -E 'openstack_(dns|grpc)_harness|grpc_fast_cache' | grep -v grep || true
ss -lunp | grep ':53 ' || true
ss -ltnp | grep -E ':5005[12] ' || true
cat /tmp/vnet-grpc-backend.log /tmp/vnet-grpc-cache.log 2>/dev/null || true" \
    > "$out_dir/service-state.txt"

printf 'round,baseline_qps,cache_qps,speedup,baseline_p99_us,cache_p99_us\n' \
    > "$out_dir/grpc-five-rounds.csv"
start_dns_monitor grpc-coexist
start_grpc_monitor grpc-coexist
verify_tc_order grpc-coexist
for round in $(seq 1 "$rounds"); do
    if ! baseline=$(guest_cmd "$client_ip" \
        "/tmp/openstack_grpc_harness client '$backend_ip' 50051 '$requests' '$warmup' '$payload'"); then
        echo "gRPC baseline failed in round $round" >&2
        cat "$out_dir/service-state.txt" >&2
        exit 1
    fi
    if ! cache=$(guest_cmd "$client_ip" \
        "/tmp/openstack_grpc_harness client '$backend_ip' 50052 '$requests' '$warmup' '$payload'"); then
        echo "gRPC cache path failed in round $round" >&2
        cat "$out_dir/service-state.txt" >&2
        exit 1
    fi
    speedup=$(awk -v cache="$(field "$cache" qps)" \
        -v baseline="$(field "$baseline" qps)" \
        'BEGIN {printf "%.4f", cache / baseline}')
    printf '%s,%s,%s,%s,%s,%s\n' "$round" \
        "$(field "$baseline" qps)" "$(field "$cache" qps)" "$speedup" \
        "$(field "$baseline" p99_us)" "$(field "$cache" p99_us)" \
        >> "$out_dir/grpc-five-rounds.csv"
done
stop_monitors

printf 'round,dns_qps,grpc_qps,dns_failed,grpc_failed\n' \
    > "$out_dir/mixed-five-rounds.csv"
for round in $(seq 1 "$rounds"); do
    start_dns_monitor "mixed-$round"
    start_grpc_monitor "mixed-$round"
    verify_tc_order "mixed-$round"
    guest_cmd "$client_ip" \
        "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' '$requests' '$warmup' >/tmp/mixed-dns.out &
dns_job=\$!
/tmp/openstack_grpc_harness client '$backend_ip' 50052 '$requests' '$warmup' '$payload' >/tmp/mixed-grpc.out &
grpc_job=\$!
wait \$dns_job
wait \$grpc_job
cat /tmp/mixed-dns.out
cat /tmp/mixed-grpc.out" > "$out_dir/mixed-$round.raw"
    dns_line=$(grep '^success=' "$out_dir/mixed-$round.raw" | head -n 1)
    grpc_line=$(grep '^count=' "$out_dir/mixed-$round.raw" | head -n 1)
    printf '%s,%s,%s,%s,%s\n' "$round" \
        "$(field "$dns_line" qps)" "$(field "$grpc_line" qps)" \
        "$(field "$dns_line" failed)" "$(field "$grpc_line" failed)" \
        >> "$out_dir/mixed-five-rounds.csv"
    stop_monitors
done

printf 'round,status,update_us,qps,serving,not_serving,failed\n' \
    > "$out_dir/dynamic-five-rounds.csv"
start_grpc_monitor dynamic
for round in $(seq 1 "$rounds"); do
    if (( round % 2 )); then
        status=NOT_SERVING
    else
        status=SERVING
    fi
    started=$(date +%s%N)
    install_status "$status" > "$out_dir/dynamic-$round-update.log"
    finished=$(date +%s%N)
    result=$(guest_cmd "$client_ip" \
        "/tmp/openstack_grpc_harness client '$backend_ip' 50052 200 20 '$payload'")
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$round" "$status" \
        "$(((finished - started) / 1000))" "$(field "$result" qps)" \
        "$(field "$result" serving)" "$(field "$result" not_serving)" \
        "$(field "$result" failed)" >> "$out_dir/dynamic-five-rounds.csv"
done
stop_monitors

awk -F, '
    FNR == 1 {next}
    {base += $2; cache += $3; speed += $4; count++}
    END {printf "grpc_rounds=%d\ngrpc_mean_baseline_qps=%.2f\ngrpc_mean_cache_qps=%.2f\ngrpc_mean_speedup=%.4f\n",
         count, base/count, cache/count, speed/count}
' "$out_dir/grpc-five-rounds.csv" > "$out_dir/aggregate.txt"
awk -F, '
    FNR == 1 {next}
    {dns += $2; grpc += $3; failed += $4 + $5; count++}
    END {printf "mixed_rounds=%d\nmixed_mean_dns_qps=%.2f\nmixed_mean_grpc_qps=%.2f\nmixed_failed=%d\n",
         count, dns/count, grpc/count, failed}
' "$out_dir/mixed-five-rounds.csv" >> "$out_dir/aggregate.txt"
awk -F, '
    FNR == 1 {next}
    {update += $3; qps += $4; failed += $7; count++}
    END {printf "dynamic_rounds=%d\ndynamic_mean_update_us=%.2f\ndynamic_mean_qps=%.2f\ndynamic_failed=%d\n",
         count, update/count, qps/count, failed}
' "$out_dir/dynamic-five-rounds.csv" >> "$out_dir/aggregate.txt"
cat "$out_dir/aggregate.txt"
