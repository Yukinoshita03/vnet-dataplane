#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
accel_dir=$(cd "$script_dir/.." && pwd)
out_dir=${OUT_DIR:-$accel_dir/artifacts/openstack-grpc-e2e/$(date +%Y%m%d-%H%M%S)}
prefix=${NAME_PREFIX:-codex-grpc-e2e-$(date +%Y%m%d-%H%M%S)-$$}
openrc=${OPENRC:-/opt/stack/devstack/openrc}
openrc_user=${OPENRC_USER:-admin}
openrc_project=${OPENRC_PROJECT:-admin}
network=${NETWORK:-private}
image=${IMAGE:-cirros-0.6.3-x86_64-disk}
flavor=${FLAVOR:-cirros256}
key_name=${KEY_NAME:-}
compute_host=${COMPUTE_HOST:-master}
subnet_cidr=${SUBNET_CIDR:-10.0.0.0/26}
use_floating_ip=${USE_FLOATING_IP:-0}
floating_network=${FLOATING_NETWORK:-public}
floating_cidr=${FLOATING_CIDR:-172.24.4.0/24}
requests=${REQUESTS:-500}
warmup=${WARMUP:-50}
backend_delay=${BACKEND_DELAY_US:-300}
cirros_password=${CIRROS_PASSWORD:-gocubsgo}
cirros_sudo_password=${CIRROS_SUDO_PASSWORD:-$cirros_password}
guest_user=${GUEST_USER:-cirros}
guest_key=${GUEST_KEY:-}
guest_password=${GUEST_PASSWORD:-$cirros_password}
guest_sudo_password=${GUEST_SUDO_PASSWORD:-$cirros_sudo_password}
sudo_password=${SUDO_PASS:-}
netns=${NETNS:-auto}
guest_bpf=${GUEST_BPF:-auto}
ssh_wait_attempts=${SSH_WAIT_ATTEMPTS:-120}
keep_resources=${KEEP_RESOURCES:-0}
cache_ttl=${CACHE_TTL_SEC:-600}
payload=${PAYLOAD:-demo}
method=/grpc.health.v1.Health/Check

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
OpenStack VM-to-VM gRPC benchmark

Creates temporary backend, cache, and client VMs; compares direct h2c Health
Check RPCs with grpc_fast_cache hits; verifies cache-only replies and a runtime
SERVING-to-NOT_SERVING response-map update; and removes all temporary
OpenStack resources on exit.

Configuration is supplied through environment variables. See
linux_accel/docs/openstack-grpc-e2e.md for the complete list.
EOF
    exit 0
fi

backend_id=
cache_id=
client_id=
security_group_id=
rule_ids=()
floating_ip_ids=()
quota_changed=0
original_quota=
monitor_pid=
pin_dir=/sys/fs/bpf/$prefix
mkdir -p "$out_dir"
run_log="$out_dir/run.log"
exec > >(tee "$run_log") 2>&1

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
sudo_cmd() {
    if [ -n "$sudo_password" ]; then
        printf '%s\n' "$sudo_password" | sudo -S -p '' "$@"
    else
        sudo "$@"
    fi
}
[ "$netns" = auto ] && netns=$(sudo_cmd ip netns list | awk '/^ovnmeta-/{print $1; exit}')
[ "$use_floating_ip" = 1 ] && netns=
[ "$netns" = none ] && netns=

ssh_guest() {
    ip=$1
    shift
    opts=(-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    if [ -n "$guest_key" ]; then
        opts+=(-i "$guest_key" -o BatchMode=yes)
        if [ -n "$netns" ]; then
            sudo_cmd ip netns exec "$netns" ssh "${opts[@]}" "$guest_user@$ip" "$@"
        else
            ssh "${opts[@]}" "$guest_user@$ip" "$@"
        fi
    elif [ -n "$netns" ]; then
        sudo_cmd env SSHPASS="$guest_password" ip netns exec "$netns" sshpass -e ssh "${opts[@]}" "$guest_user@$ip" "$@"
    else
        env SSHPASS="$guest_password" sshpass -e ssh "${opts[@]}" "$guest_user@$ip" "$@"
    fi
}
ssh_guest_tty() {
    ip=$1
    shift
    opts=(-tt -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    if [ -n "$guest_key" ]; then
        opts+=(-i "$guest_key" -o BatchMode=yes)
        if [ -n "$netns" ]; then
            sudo_cmd ip netns exec "$netns" ssh "${opts[@]}" "$guest_user@$ip" "$@"
        else
            ssh "${opts[@]}" "$guest_user@$ip" "$@"
        fi
    elif [ -n "$netns" ]; then
        sudo_cmd env SSHPASS="$guest_password" ip netns exec "$netns" sshpass -e ssh "${opts[@]}" "$guest_user@$ip" "$@"
    else
        env SSHPASS="$guest_password" sshpass -e ssh "${opts[@]}" "$guest_user@$ip" "$@"
    fi
}
guest_cmd() {
    ip=$1
    command=$2
    encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
    ssh_guest "$ip" "echo $encoded | base64 -d | sh"
}
guest_root_cmd() {
    ip=$1
    command=$2
    encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
    ssh_guest "$ip" "echo $encoded | base64 -d | sh"
}
copy_guest() {
    ip=$1
    source_file=$2
    target_file=$3
    opts=(-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    echo "copy $(basename "$source_file") -> $ip:$target_file"
    if [ -n "$guest_key" ]; then
        if [ -n "$netns" ]; then
            base64 "$source_file" | sudo_cmd ip netns exec "$netns" ssh "${opts[@]}" -i "$guest_key" -o BatchMode=yes "$guest_user@$ip" "base64 -d > '$target_file' && chmod +x '$target_file'"
        else
            base64 "$source_file" | ssh "${opts[@]}" -i "$guest_key" -o BatchMode=yes "$guest_user@$ip" "base64 -d > '$target_file' && chmod +x '$target_file'"
        fi
    elif [ -n "$netns" ]; then
        if [ -n "$sudo_password" ]; then
            { printf '%s\n' "$sudo_password"; base64 "$source_file" | tr -d '\n'; } |
                sudo -S -p '' env SSHPASS="$guest_password" ip netns exec "$netns" sshpass -e ssh "${opts[@]}" "$guest_user@$ip" "base64 -d > '$target_file' && chmod +x '$target_file'"
        else
            base64 "$source_file" | tr -d '\n' |
                sudo env SSHPASS="$guest_password" ip netns exec "$netns" sshpass -e ssh "${opts[@]}" "$guest_user@$ip" "base64 -d > '$target_file' && chmod +x '$target_file'"
        fi
    else
        base64 "$source_file" | tr -d '\n' |
            env SSHPASS="$guest_password" sshpass -e ssh "${opts[@]}" "$guest_user@$ip" "base64 -d > '$target_file' && chmod +x '$target_file'"
    fi
}
server_ip() {
    openstack server show "$1" -f json -c addresses |
        python3 -c 'import json, sys; data=json.load(sys.stdin); addresses=data.get("addresses", {}); items=[item.get("addr", "") if isinstance(item, dict) else str(item) for values in addresses.values() for item in values]; print(next((token.strip(" []\\\"") for item in items for token in item.split(",") if token.strip(" []\\\"").count(".") == 3), ""))'
}
ssh_server_ip() {
    local server_id=$1
    if [ "$use_floating_ip" = 1 ]; then
        local floating_ip floating_id
        echo "allocating floating IP for server $server_id" >&2
        floating_ip=$(openstack floating ip create "$floating_network" -f value -c floating_ip_address)
        floating_id=$(openstack floating ip show "$floating_ip" -f value -c id)
        echo "attaching floating IP $floating_ip to server $server_id" >&2
        openstack server add floating ip "$server_id" "$floating_ip" >/dev/null
        floating_ip_ids+=("$floating_id")
        printf '%s\n' "$floating_id" >> "$out_dir/floating_ip_ids"
        printf '%s\n' "$floating_ip"
    else
        server_ip "$server_id"
    fi
}
delete_server() {
    [ -n "$1" ] && openstack server delete --wait "$1" >/dev/null 2>&1 || true
}
cleanup() {
    cleanup_status=$?
    set +e
    [ -n "$monitor_pid" ] && sudo_cmd kill "$monitor_pid" >/dev/null 2>&1 || true
    sudo_cmd rm -rf -- "$pin_dir" >/dev/null 2>&1 || true
    if [ "$keep_resources" = 1 ]; then
        echo "KEEP_RESOURCES=1; preserving temporary servers, floating IPs, and security group"
    else
        delete_server "$backend_id"
        delete_server "$cache_id"
        delete_server "$client_id"
        for id in "${floating_ip_ids[@]}"; do
            [ -n "$id" ] && openstack floating ip delete "$id" >/dev/null 2>&1 || true
        done
        if [ -f "$out_dir/floating_ip_ids" ]; then
            while IFS= read -r id; do
                [ -n "$id" ] && openstack floating ip delete "$id" >/dev/null 2>&1 || true
            done < "$out_dir/floating_ip_ids"
        fi
        for id in "${rule_ids[@]}"; do
            [ -n "$id" ] && openstack security group rule delete "$id" >/dev/null 2>&1 || true
        done
        [ -n "$security_group_id" ] && openstack security group delete "$security_group_id" >/dev/null 2>&1 || true
    fi
    if [ "$quota_changed" -eq 1 ]; then
        openstack quota set --instances "$original_quota" "$project_id" >/dev/null 2>&1 || true
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        echo "benchmark failed with exit=$cleanup_status"
        if [ -n "${project_id:-}" ]; then
            openstack server list --project "$project_id" --all -f value -c ID -c Name -c Status || true
        fi
    fi
    echo "cleanup complete (exit=$cleanup_status)"
}
trap cleanup EXIT

for cmd in openstack ssh sshpass base64 awk grep ip sudo gcc c++ timeout pgrep python3; do need "$cmd"; done
[ -f "$openrc" ] || { echo "missing openrc: $openrc" >&2; exit 1; }
# shellcheck disable=SC1090
set +u
source "$openrc" "$openrc_user" "$openrc_project"
set -u
project_id=${OS_PROJECT_ID:-$(openstack project show admin -f value -c id)}
original_quota=$(openstack quota show "$project_id" -f csv |
    awk -F, '$1 ~ /instances/ {print $2; exit}' | tr -d '"')
used_instances=$(openstack server list --project "$project_id" --all -f value -c ID | wc -l)
if [[ "$original_quota" =~ ^-?[0-9]+$ ]] &&
   [ "$original_quota" -ge 0 ] &&
   [ $((used_instances + 3)) -gt "$original_quota" ]; then
    echo "raising instance quota from $original_quota to $((original_quota + 3))"
    openstack quota set --instances "$((original_quota + 3))" "$project_id"
    quota_changed=1
elif [[ ! "$original_quota" =~ ^-?[0-9]+$ ]]; then
    echo "warning: unable to parse instance quota: $original_quota"
fi

security_group_id=$(openstack security group create "$prefix-sg" --project "$project_id" -f value -c id)
ssh_cidr=$subnet_cidr
[ "$use_floating_ip" = 1 ] && ssh_cidr=$floating_cidr
rule_ids+=("$(openstack security group rule create "$security_group_id" --protocol tcp --dst-port 22 --remote-ip "$ssh_cidr" -f value -c id)")
rule_ids+=("$(openstack security group rule create "$security_group_id" --protocol tcp --dst-port 50051:50052 --remote-ip "$subnet_cidr" -f value -c id)")
create_server() {
    name=$1
    echo "creating server $name" >&2
    key_args=()
    [ -n "$key_name" ] && key_args+=(--key-name "$key_name")
    if ! id=$(openstack server create --wait --availability-zone "nova:$compute_host" \
        --flavor "$flavor" --image "$image" --network "$network" \
        --security-group "$security_group_id" "${key_args[@]}" "$name" -f value -c id); then
        echo "server create failed: $name" >&2
        openstack server list --project "$project_id" --all -f value -c ID -c Name -c Status >&2 || true
        return 1
    fi
    printf '%s\n' "$id"
}
backend_id=$(create_server "$prefix-backend")
cache_id=$(create_server "$prefix-cache")
client_id=$(create_server "$prefix-client")
backend_ip=$(server_ip "$backend_id")
cache_ip=$(server_ip "$cache_id")
client_ip=$(server_ip "$client_id")
backend_ssh_ip=$(ssh_server_ip "$backend_id")
cache_ssh_ip=$(ssh_server_ip "$cache_id")
client_ssh_ip=$(ssh_server_ip "$client_id")
for endpoint in backend_ip cache_ip client_ip; do
    [ -n "${!endpoint}" ] || { echo "failed to discover $endpoint" >&2; exit 1; }
done
printf 'backend=%s backend_ssh=%s cache=%s cache_ssh=%s client=%s client_ssh=%s\n' \
    "$backend_ip" "$backend_ssh_ip" "$cache_ip" "$cache_ssh_ip" "$client_ip" "$client_ssh_ip" | tee "$out_dir/topology.txt"

for ip in "$backend_ssh_ip" "$cache_ssh_ip" "$client_ssh_ip"; do
    ready=0
    for _ in $(seq 1 "$ssh_wait_attempts"); do
        if ssh_guest "$ip" true >/dev/null 2>&1; then ready=1; break; fi
        sleep 2
    done
    if [ "$ready" -ne 1 ]; then
        echo "SSH timeout: $ip" >&2
        openstack server show "$([ "$ip" = "$backend_ssh_ip" ] && echo "$backend_id" || [ "$ip" = "$cache_ssh_ip" ] && echo "$cache_id" || echo "$client_id")" >&2 || true
        exit 1
    fi
done

harness="$out_dir/openstack_grpc_harness"
cache_binary="$out_dir/grpc_fast_cache.static"
cachectl_binary="$out_dir/cachectl.static"
gcc -O2 -static "$script_dir/openstack_grpc_harness.c" -o "$harness"
c++ -std=c++17 -O2 -static -I"$accel_dir/src/include" -I"$accel_dir/include" \
    "$accel_dir/src/grpc_fast_cache.cpp" "$accel_dir/src/cache_policy.cpp" \
    "$accel_dir/src/grpc_cache_protocol.cpp" \
    "$accel_dir/src/dns_cache_config.cpp" -o "$cache_binary" \
    -lbpf -lelf -lz -lzstd -static-libstdc++ -static-libgcc
c++ -std=c++17 -O2 -static -I"$accel_dir/src/include" -I"$accel_dir/include" \
    "$accel_dir/src/cachectl.cpp" "$accel_dir/src/cache_policy.cpp" \
    "$accel_dir/src/dns_cache_config.cpp" -o "$cachectl_binary" \
    -lbpf -lelf -lz -lzstd -static-libstdc++ -static-libgcc
copy_guest "$backend_ssh_ip" "$harness" /tmp/openstack_grpc_harness
copy_guest "$cache_ssh_ip" "$harness" /tmp/openstack_grpc_harness
copy_guest "$client_ssh_ip" "$harness" /tmp/openstack_grpc_harness
copy_guest "$cache_ssh_ip" "$cache_binary" /tmp/grpc_fast_cache
copy_guest "$cache_ssh_ip" "$cachectl_binary" /tmp/cachectl

if [ -n "$guest_key" ]; then
    guest_sudo="sudo -n"
else
    guest_sudo="printf '%s\\n' '$guest_sudo_password' | sudo -S -p ''"
fi
guest_cmd "$backend_ssh_ip" "nohup /tmp/openstack_grpc_harness server $backend_ip 50051 $backend_delay >/tmp/openstack-grpc-backend.log 2>&1 </dev/null &"
if [ "$guest_bpf" = auto ]; then
    if guest_cmd "$cache_ssh_ip" "grep -q ' /sys/fs/bpf bpf ' /proc/mounts" >/dev/null 2>&1; then
        guest_bpf=1
    else
        guest_bpf=0
    fi
fi
case "$guest_bpf" in
    1)
        cache_mode=guest-ebpf
        cache_setup="cat >/tmp/openstack-grpc-policy.txt <<'EOF'
grpc $method 60 idempotent
grpc-cache $method $payload SERVING $cache_ttl
EOF
$guest_sudo sh -c 'mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf; rm -f /sys/fs/bpf/grpc_policy_map /sys/fs/bpf/grpc_response_cache; /tmp/openstack_grpc_harness seed /sys/fs/bpf/grpc_policy_map; /tmp/openstack_grpc_harness seed-response /sys/fs/bpf/grpc_response_cache $payload SERVING $cache_ttl; /tmp/cachectl --policy-file /tmp/openstack-grpc-policy.txt --grpc-map /sys/fs/bpf/grpc_policy_map --grpc-response-map /sys/fs/bpf/grpc_response_cache --replace >/tmp/openstack-grpc-cachectl.log 2>&1'
$guest_sudo sh -c 'nohup /tmp/grpc_fast_cache --grpc-map /sys/fs/bpf/grpc_policy_map --grpc-response-map /sys/fs/bpf/grpc_response_cache --listen $cache_ip:50052 --backend $backend_ip:50051 --method $method --verbose >/tmp/openstack-grpc-cache.log 2>&1 </dev/null &'"
        guest_root_cmd "$cache_ssh_ip" "$cache_setup" >/dev/null
        ;;
    0)
        cache_mode=guest-userspace-fallback
        cache_setup="cat >/tmp/openstack-grpc-policy.txt <<'EOF'
grpc $method 60 idempotent
grpc-cache $method $payload SERVING $cache_ttl
EOF
nohup /tmp/grpc_fast_cache --cache-file /tmp/openstack-grpc-policy.txt --listen $cache_ip:50052 --backend $backend_ip:50051 --method $method --verbose >/tmp/openstack-grpc-cache.log 2>&1 </dev/null & echo \$! >/tmp/openstack-grpc-cache.pid"
        guest_cmd "$cache_ssh_ip" "$cache_setup" >/dev/null
        printf 'mode=guest-userspace-fallback\nreason=guest kernel has no mounted bpffs\n' > "$out_dir/cachectl.log"
        ;;
    *)
        echo "GUEST_BPF must be auto, 0, or 1" >&2
        exit 1
        ;;
esac
sleep 2

if [ "$guest_bpf" = 1 ]; then
    guest_cmd "$cache_ssh_ip" "sudo -n bpftool map dump pinned /sys/fs/bpf/grpc_response_cache" \
        > "$out_dir/response-map.dump" 2>&1 || true
    guest_cmd "$cache_ssh_ip" "sudo -n bpftool map dump pinned /sys/fs/bpf/grpc_policy_map" \
        > "$out_dir/policy-map.dump" 2>&1 || true
fi

cache_port_id=$(openstack port list --server "$cache_id" -f value -c ID | head -n1)
tap_if=tap$(echo "$cache_port_id" | cut -c1-11)
monitor_log="$out_dir/grpc-monitor.log"
if [ -f "$accel_dir/build/grpc_monitor" ] && [ -f "$accel_dir/build/grpc_monitor.bpf.o" ] && ip link show "$tap_if" >/dev/null 2>&1; then
    if [ -n "$sudo_password" ]; then
        printf '%s\n' "$sudo_password" | sudo -S -p '' bash -c "nohup timeout 40s '$accel_dir/build/grpc_monitor' --dev '$tap_if' --bpf-object '$accel_dir/build/grpc_monitor.bpf.o' --port 50052 --pin-dir '$pin_dir' --verbose-events >'$monitor_log' 2>&1 </dev/null &"
    else
        sudo bash -c "nohup timeout 40s '$accel_dir/build/grpc_monitor' --dev '$tap_if' --bpf-object '$accel_dir/build/grpc_monitor.bpf.o' --port 50052 --pin-dir '$pin_dir' --verbose-events >'$monitor_log' 2>&1 </dev/null &"
    fi
    monitor_pid=$(pgrep -f "$accel_dir/build/grpc_monitor --dev $tap_if" | head -n1 || true)
    for _ in $(seq 1 20); do
        grep -q 'Listening for gRPC' "$monitor_log" 2>/dev/null && break
        sleep 1
    done
    monitor_pid=$(pgrep -f "$accel_dir/build/grpc_monitor --dev $tap_if" | head -n1 || true)
else
    echo "warning: grpc monitor build or cache tap unavailable" | tee "$monitor_log"
fi

baseline_line=$(guest_cmd "$client_ssh_ip" "/tmp/openstack_grpc_harness client $backend_ip 50051 $requests $warmup $payload")
cache_line=$(guest_cmd "$client_ssh_ip" "/tmp/openstack_grpc_harness client $cache_ip 50052 $requests $warmup $payload")
printf '%s\n' "$baseline_line" | tee "$out_dir/baseline.log"
printf '%s\n' "$cache_line" | tee "$out_dir/cache.log"
if [ "$guest_bpf" = 1 ]; then
    guest_cmd "$cache_ssh_ip" "cat /tmp/openstack-grpc-cachectl.log" > "$out_dir/cachectl.log" || true
fi
guest_cmd "$cache_ssh_ip" "cat /tmp/openstack-grpc-cache.log" > "$out_dir/cache-process.log" || true
guest_cmd "$backend_ssh_ip" "killall openstack_grpc_harness || true"
set +e
cache_only_line=$(guest_cmd "$client_ssh_ip" "/tmp/openstack_grpc_harness client $cache_ip 50052 100 10 $payload")
cache_only_rc=$?
set -e
printf '%s\n' "$cache_only_line" | tee "$out_dir/cache-only.log"
if [ "$cache_only_rc" -ne 0 ]; then
    echo "cache-only probe failed (rc=$cache_only_rc)" >&2
    guest_cmd "$cache_ssh_ip" "cat /tmp/openstack-grpc-cache.log; echo ---; ps -ef | grep grpc_fast_cache | grep -v grep || true; echo ---; ss -ltnp | grep 50052 || true" \
        > "$out_dir/cache-only-process.log" || true
    exit 1
fi
update_setup="cat >/tmp/openstack-grpc-policy-update.txt <<'EOF'
grpc-cache $method $payload NOT_SERVING $cache_ttl
EOF
"
if [ "$guest_bpf" = 1 ]; then
    update_setup="$update_setup
$guest_sudo sh -c '/tmp/cachectl --policy-file /tmp/openstack-grpc-policy-update.txt --grpc-response-map /sys/fs/bpf/grpc_response_cache --replace >/tmp/openstack-grpc-cache-update.log 2>&1'"
    guest_root_cmd "$cache_ssh_ip" "$update_setup" >/dev/null
else
update_setup="$update_setup
if [ -f /tmp/openstack-grpc-cache.pid ]; then kill -9 \$(cat /tmp/openstack-grpc-cache.pid) >/dev/null 2>&1 || true; fi
sleep 1
nohup /tmp/grpc_fast_cache --cache-file /tmp/openstack-grpc-policy-update.txt --listen $cache_ip:50052 --backend $backend_ip:50051 --method $method --verbose >/tmp/openstack-grpc-cache.log 2>&1 </dev/null & echo \$! >/tmp/openstack-grpc-cache.pid"
    if ! guest_cmd "$cache_ssh_ip" "$update_setup" > "$out_dir/cache-update-command.log"; then
        echo "cache update command failed" >&2
        cat "$out_dir/cache-update-command.log" >&2 || true
        exit 1
    fi
    sleep 2
    printf 'mode=guest-userspace-fallback\ncache_file=/tmp/openstack-grpc-policy-update.txt\n' > "$out_dir/cache-updatectl.log"
fi
set +e
cache_update_line=$(guest_cmd "$client_ssh_ip" "/tmp/openstack_grpc_harness client $cache_ip 50052 20 5 $payload")
cache_update_rc=$?
set -e
printf '%s\n' "$cache_update_line" | tee "$out_dir/cache-update.log"
guest_cmd "$cache_ssh_ip" "cat /tmp/openstack-grpc-cache.log" > "$out_dir/cache-update-process.log" || true
if [ "$cache_update_rc" -ne 0 ]; then
    echo "cache update probe failed (rc=$cache_update_rc)" >&2
    tail -n 40 "$out_dir/cache-update-process.log" >&2 || true
    exit 1
fi
if [ "$guest_bpf" = 1 ]; then
    guest_cmd "$cache_ssh_ip" "cat /tmp/openstack-grpc-cache-update.log" > "$out_dir/cache-updatectl.log" || true
fi
[ -n "$monitor_pid" ] && sudo_cmd kill "$monitor_pid" >/dev/null 2>&1 || true
monitor_pid=

field() { tr ' ' '\n' <<<"$1" | awk -F= -v key="$2" '$1 == key {print $2; exit}'; }
baseline_qps=$(field "$baseline_line" qps)
cache_qps=$(field "$cache_line" qps)
baseline_avg=$(field "$baseline_line" avg_us)
cache_avg=$(field "$cache_line" avg_us)
baseline_p99=$(field "$baseline_line" p99_us)
cache_p99=$(field "$cache_line" p99_us)
cache_update_not_serving=$(field "$cache_update_line" not_serving)
if [ "${cache_update_not_serving:-0}" -ne 20 ]; then
    echo "dynamic response-map update failed: $cache_update_line" >&2
    exit 1
fi
qps_ratio=$(awk -v a="$cache_qps" -v b="$baseline_qps" 'BEGIN {if (b > 0) printf "%.2f", a/b; else print "0.00"}')
avg_reduction=$(awk -v a="$cache_avg" -v b="$baseline_avg" 'BEGIN {if (b > 0) printf "%.1f", (1-a/b)*100; else print "0.0"}')
p99_reduction=$(awk -v a="$cache_p99" -v b="$baseline_p99" 'BEGIN {if (b > 0) printf "%.1f", (1-a/b)*100; else print "0.0"}')

cat > "$out_dir/summary.md" <<EOF
# OpenStack VM-to-VM gRPC E2E

topology: client $client_ip -> cache $cache_ip:50052 -> backend $backend_ip:50051
network: $network
cache_mode: $cache_mode
method: $method
requests: $requests
warmup: $warmup
backend_delay_us: $backend_delay
tap: $tap_if

| path | qps | avg_us | p99_us |
| --- | ---: | ---: | ---: |
| direct backend | $(field "$baseline_line" qps) | $(field "$baseline_line" avg_us) | $(field "$baseline_line" p99_us) |
| cache hit | $(field "$cache_line" qps) | $(field "$cache_line" avg_us) | $(field "$cache_line" p99_us) |

qps_speedup: $qps_ratio
avg_latency_reduction: $avg_reduction%
p99_latency_reduction: $p99_reduction%
cache_only_after_backend_stop: $cache_only_line
cache_update_to_not_serving: $cache_update_line
cachectl:
$(cat "$out_dir/cachectl.log" 2>/dev/null || true)
cache_updatectl:
$(cat "$out_dir/cache-updatectl.log" 2>/dev/null || true)
cache_process_tail:
$(tail -n 10 "$out_dir/cache-process.log" 2>/dev/null || true)
grpc_monitor:
$(grep 'grpc_metrics' "$monitor_log" | tail -n 3 || true)
EOF
cat "$out_dir/summary.md"
