#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
accel_dir=$(cd "$script_dir/.." && pwd)
out_dir=${OUT_DIR:-$accel_dir/artifacts/openstack-dns-e2e/$(date +%Y%m%d-%H%M%S)}
prefix=${NAME_PREFIX:-codex-dns-e2e-$(date +%Y%m%d-%H%M%S)-$$}
openrc=${OPENRC:-/opt/stack/devstack/openrc}
openrc_user=${OPENRC_USER:-admin}
openrc_project=${OPENRC_PROJECT:-admin}
network=${NETWORK:-private}
image=${IMAGE:-ubuntu-24.04-noble-cloud}
flavor=${FLAVOR:-m1.small}
floating_network=${FLOATING_NETWORK:-public}
use_floating_ip=${USE_FLOATING_IP:-1}
floating_cidr=${FLOATING_CIDR:-172.24.4.0/24}
netns=${NETNS:-auto}
key_name=${KEY_NAME:-}
guest_key=${GUEST_KEY:-}
guest_user=${GUEST_USER:-ubuntu}
requests=${REQUESTS:-1000}
warmup=${WARMUP:-100}
repeat=${REPEAT:-5}
domain=${DOMAIN:-example.test}
answer_ip=${ANSWER_IP:-10.0.0.123}
backend_ttl=${BACKEND_TTL_SEC:-60}
guest_bpf=${GUEST_BPF:-1}
ssh_wait_attempts=${SSH_WAIT_ATTEMPTS:-120}
keep_resources=${KEEP_RESOURCES:-0}
sudo_password=${SUDO_PASS:-}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
OpenStack VM-to-VM DNS dual-ended cache benchmark

Creates temporary Ubuntu client/backend VMs and compares baseline, tc monitor,
server XDP cache, client XDP learning cache, and both-cache paths. The script
also checks TTL expiry, untrusted resolver isolation, NXDOMAIN rejection, and
resource cleanup. Ubuntu guest eBPF is required unless GUEST_BPF=0 is used for
an explicitly labelled dry fallback run.
EOF
    exit 0
fi

[[ -n "$guest_key" ]] || {
    echo "GUEST_KEY must point to an SSH private key for the Ubuntu image" >&2
    exit 1
}
[[ -r "$guest_key" ]] || { echo "GUEST_KEY is not readable: $guest_key" >&2; exit 1; }

backend_id=
client_id=
backend_ssh_ip=
client_ssh_ip=
security_group_id=
floating_ip_ids=()
monitor_pids=()
mkdir -p "$out_dir"
exec > >(tee "$out_dir/run.log") 2>&1

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
openstack_cmd() { openstack "$@"; }
sudo_cmd() {
    if [[ -n "$sudo_password" ]]; then
        printf '%s\n' "$sudo_password" | sudo -S -p '' "$@"
    else
        sudo "$@"
    fi
}
guest_opts=(-i "$guest_key" -o BatchMode=yes -o ConnectTimeout=8
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

ssh_guest() {
    local ip=$1
    shift
    if [[ -n "$netns" ]]; then
        sudo_cmd ip netns exec "$netns" ssh "${guest_opts[@]}" "$guest_user@$ip" "$@"
    else
        ssh "${guest_opts[@]}" "$guest_user@$ip" "$@"
    fi
}

guest_cmd() {
    local ip=$1
    local command=$2
    local encoded
    encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
    ssh_guest "$ip" "echo $encoded | base64 -d | bash"
}

guest_root_cmd() {
    local ip=$1
    local command=$2
    local encoded
    encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
    ssh_guest "$ip" "echo $encoded | base64 -d | sudo -n bash"
}

copy_guest() {
    local ip=$1
    local source_file=$2
    local target_file=$3
    if [[ -n "$netns" ]]; then
        base64 "$source_file" | tr -d '\n' | sudo_cmd ip netns exec "$netns" \
            ssh "${guest_opts[@]}" "$guest_user@$ip" \
            "base64 -d > '$target_file' && chmod +x '$target_file'"
    else
        base64 "$source_file" | tr -d '\n' | ssh "${guest_opts[@]}" \
            "$guest_user@$ip" "base64 -d > '$target_file' && chmod +x '$target_file'"
    fi
}

server_fixed_ip() {
    openstack_cmd server show "$1" -f json -c addresses |
        python3 -c 'import json,sys; d=json.load(sys.stdin).get("addresses",{}); xs=[]; [xs.extend(v if isinstance(v,list) else [v]) for v in d.values()]; print(next((str(x.get("addr",x)) for x in xs if isinstance(x,dict) and str(x.get("addr","")).count(".")==3), next((str(x) for x in xs if str(x).count(".")==3), "")))'
}

allocate_floating_ip() {
    local server_id=$1
    local address id
    address=$(openstack_cmd floating ip create "$floating_network" -f value -c floating_ip_address)
    id=$(openstack_cmd floating ip show "$address" -f value -c id)
    openstack_cmd server add floating ip "$server_id" "$address" >/dev/null
    floating_ip_ids+=("$id")
    printf '%s\n' "$address"
}

create_server() {
    openstack_cmd server create --wait \
        --image "$image" --flavor "$flavor" --network "$network" \
        --security-group "$security_group_id" --key-name "$key_name" \
        "$1" -f value -c id
}

backend_count() {
    guest_cmd "$backend_ssh_ip" "test -s /tmp/dns-backend-count && tr -d '[:space:]' < /tmp/dns-backend-count || printf 0"
}

stop_guest_processes() {
    guest_root_cmd "$backend_ssh_ip" 'if [ -f /tmp/dns-backend.pid ]; then kill "$(cat /tmp/dns-backend.pid)" 2>/dev/null || true; fi; rm -f /tmp/dns-backend.pid /tmp/dns-backend-count; pkill -TERM -f "/tmp/dns_monitor" 2>/dev/null || true; true' || true
    guest_root_cmd "$client_ssh_ip" 'if [ -f /tmp/dns-client-monitor.pid ]; then kill "$(cat /tmp/dns-client-monitor.pid)" 2>/dev/null || true; fi; rm -f /tmp/dns-client-monitor.pid; pkill -TERM -f "/tmp/dns_monitor" 2>/dev/null || true; true' || true
}

cleanup() {
    local status=$?
    set +e
    if [[ -n "$backend_ssh_ip" && -n "$client_ssh_ip" ]]; then
        stop_guest_processes
    fi
    if [[ "$keep_resources" != 1 ]]; then
        [[ -n "$backend_id" ]] && openstack_cmd server delete --wait "$backend_id" >/dev/null 2>&1 || true
        [[ -n "$client_id" ]] && openstack_cmd server delete --wait "$client_id" >/dev/null 2>&1 || true
        for id in "${floating_ip_ids[@]}"; do
            [[ -n "$id" ]] && openstack_cmd floating ip delete "$id" >/dev/null 2>&1 || true
        done
        [[ -n "$security_group_id" ]] && openstack_cmd security group delete "$security_group_id" >/dev/null 2>&1 || true
    else
        echo "KEEP_RESOURCES=1; temporary servers and network resources preserved"
    fi
    if [[ "$status" -ne 0 ]]; then
        echo "benchmark failed with exit=$status"
        openstack_cmd server list --name "$prefix" -f value -c ID -c Name -c Status || true
    fi
    printf 'cleanup_status=%s\n' "$status" > "$out_dir/cleanup-status.txt"
    exit "$status"
}
trap cleanup EXIT

for command in openstack ssh base64 awk grep ip python3 gcc c++ timeout sudo; do need "$command"; done
[[ -f "$openrc" ]] || { echo "missing openrc: $openrc" >&2; exit 1; }
# shellcheck disable=SC1090
set +u
source "$openrc" "$openrc_user" "$openrc_project"
set -u
openstack_cmd token issue -f value -c id >/dev/null
if [[ "$netns" == auto ]]; then
    netns=$(sudo_cmd ip netns list | awk '/^ovnmeta-/{print $1; exit}')
fi
[[ "$netns" == none ]] && netns=
printf 'netns=%s\n' "${netns:-none}" > "$out_dir/environment.md"
[[ "$guest_bpf" == 0 || "$guest_bpf" == 1 ]] || {
    echo "GUEST_BPF must be 0 or 1" >&2
    exit 1
}

security_group_id=$(openstack_cmd security group create "$prefix-sg" -f value -c id)
private_cidr=${PRIVATE_CIDR:-0.0.0.0/0}
ssh_cidr=$private_cidr
[[ "$use_floating_ip" == 1 ]] && ssh_cidr=$floating_cidr
openstack_cmd security group rule create --protocol tcp --dst-port 22 \
    --remote-ip "$ssh_cidr" "$security_group_id" >/dev/null
openstack_cmd security group rule create --protocol udp --dst-port 53 \
    --remote-ip "$private_cidr" "$security_group_id" >/dev/null
openstack_cmd security group rule create --protocol icmp \
    --remote-ip "$private_cidr" "$security_group_id" >/dev/null

client_id=$(create_server "$prefix-client")
backend_id=$(create_server "$prefix-backend")
client_ip=$(server_fixed_ip "$client_id")
backend_ip=$(server_fixed_ip "$backend_id")
if [[ "$use_floating_ip" == 1 ]]; then
    client_ssh_ip=$(allocate_floating_ip "$client_id")
    backend_ssh_ip=$(allocate_floating_ip "$backend_id")
else
    client_ssh_ip=$client_ip
    backend_ssh_ip=$backend_ip
fi
[[ -n "$client_ip" && -n "$backend_ip" ]] || { echo "failed to discover fixed IPs" >&2; exit 1; }
printf 'client=%s client_ssh=%s backend=%s backend_ssh=%s\n' \
    "$client_ip" "$client_ssh_ip" "$backend_ip" "$backend_ssh_ip" | tee "$out_dir/topology.txt"
openstack_cmd server show "$client_id" > "$out_dir/client-server.txt"
openstack_cmd server show "$backend_id" > "$out_dir/backend-server.txt"
openstack_cmd port list --server "$client_id" > "$out_dir/client-ports.txt"
openstack_cmd port list --server "$backend_id" > "$out_dir/backend-ports.txt"

for endpoint in "$client_ssh_ip" "$backend_ssh_ip"; do
    ready=0
    for _ in $(seq 1 "$ssh_wait_attempts"); do
        if ssh_guest "$endpoint" true >/dev/null 2>&1; then ready=1; break; fi
        sleep 2
    done
    [[ "$ready" == 1 ]] || { echo "SSH timeout: $endpoint" >&2; exit 1; }
done

guest_root_cmd "$client_ssh_ip" 'sudo -n true && ip route show default && uname -a && mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf'
guest_root_cmd "$backend_ssh_ip" 'sudo -n true && ip route show default && uname -a && mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf'
client_dev=$(guest_cmd "$client_ssh_ip" "ip route show default | awk 'NR==1{print \$5}'")
backend_dev=$(guest_cmd "$backend_ssh_ip" "ip route show default | awk 'NR==1{print \$5}'")
printf 'client_dev=%s backend_dev=%s guest_bpf=%s\n' "$client_dev" "$backend_dev" "$guest_bpf" >> "$out_dir/topology.txt"
guest_cmd "$client_ssh_ip" "ip -br link; ip -br addr" > "$out_dir/client-interface-map.txt"
guest_cmd "$backend_ssh_ip" "ip -br link; ip -br addr" > "$out_dir/backend-interface-map.txt"

harness="$out_dir/openstack_dns_harness.static"
dns_monitor="$out_dir/dns_monitor.static"
gcc -O2 -static "$script_dir/openstack_dns_harness.c" -o "$harness"
c++ -std=c++17 -O2 -static -I"$accel_dir/src/include" -I"$accel_dir/include" \
    "$accel_dir/src/dns_cache_config.cpp" \
    "$accel_dir/src/dns_monitor.cpp" \
    "$accel_dir/src/dns_monitor_args.cpp" \
    "$accel_dir/src/dns_monitor_metrics.cpp" \
    -o "$dns_monitor" -lbpf -lelf -lz -lzstd -static-libstdc++ -static-libgcc
copy_guest "$client_ssh_ip" "$harness" /tmp/openstack_dns_harness
copy_guest "$backend_ssh_ip" "$harness" /tmp/openstack_dns_harness
copy_guest "$client_ssh_ip" "$dns_monitor" /tmp/dns_monitor
copy_guest "$backend_ssh_ip" "$dns_monitor" /tmp/dns_monitor
copy_guest "$client_ssh_ip" "$accel_dir/build/dns_client_cache.bpf.o" /tmp/dns_client_cache.bpf.o
copy_guest "$client_ssh_ip" "$accel_dir/build/dns_monitor.bpf.o" /tmp/dns_monitor.bpf.o
copy_guest "$backend_ssh_ip" "$accel_dir/build/dns_xdp_monitor.bpf.o" /tmp/dns_xdp_monitor.bpf.o
copy_guest "$backend_ssh_ip" "$accel_dir/build/dns_monitor.bpf.o" /tmp/dns_monitor.bpf.o

if [[ "$guest_bpf" == 1 ]]; then
    guest_root_cmd "$client_ssh_ip" 'mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf'
    guest_root_cmd "$backend_ssh_ip" 'mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf'
fi

start_backend() {
    local ttl=${1:-$backend_ttl}
    local mode=${2:-a}
    local mode_arg=
    [[ "$mode" == nxdomain ]] && mode_arg=nxdomain
    guest_root_cmd "$backend_ssh_ip" \
        "rm -f /tmp/dns-backend-count /tmp/dns-backend.pid; nohup /tmp/openstack_dns_harness server 0.0.0.0 53 '$domain' '$answer_ip' '$ttl' /tmp/dns-backend-count '$mode_arg' >/tmp/dns-backend.log 2>&1 </dev/null & echo \$! >/tmp/dns-backend.pid"
    sleep 1
}

start_monitor() {
    local side=$1
    local scenario=$2
    local log=/tmp/dns-${side}-${scenario}.log
    if [[ "$side" == server ]]; then
        if [[ "$scenario" == server-only || "$scenario" == both ]]; then
            guest_root_cmd "$backend_ssh_ip" \
                "nohup timeout 90 /tmp/dns_monitor --dev '$backend_dev' --hook xdp --role server --xdp-mode generic --bpf-object /tmp/dns_xdp_monitor.bpf.o --cache-domain '$domain' --cache-ip '$answer_ip' --cache-ttl '$backend_ttl' --verbose-events >'$log' 2>&1 </dev/null & echo \$! >/tmp/dns-server-monitor.pid"
        elif [[ "$scenario" == monitor-only ]]; then
            guest_root_cmd "$backend_ssh_ip" \
                "nohup timeout 90 /tmp/dns_monitor --dev '$backend_dev' --hook tc --bpf-object /tmp/dns_monitor.bpf.o --verbose-events >'$log' 2>&1 </dev/null & echo \$! >/tmp/dns-server-monitor.pid"
        fi
    else
        if [[ "$scenario" == client-only || "$scenario" == both || "$scenario" == ttl || "$scenario" == untrusted || "$scenario" == nxdomain ]]; then
            local trusted=$backend_ip
            [[ "$scenario" == untrusted ]] && trusted=10.254.254.254
            guest_root_cmd "$client_ssh_ip" \
                "nohup timeout 90 /tmp/dns_monitor --dev '$client_dev' --hook xdp --role client --xdp-mode generic --bpf-object /tmp/dns_client_cache.bpf.o --max-learn-ttl 300 --learn-window-ms 2000 --trusted-dns '$trusted' --verbose-events >'$log' 2>&1 </dev/null & echo \$! >/tmp/dns-client-monitor.pid"
        fi
    fi
    sleep 2
}

monitor_line() {
    local log=$1
    guest_cmd "$2" "grep 'dns_metrics' '$log' | tail -n 1" 2>/dev/null || true
}

run_client() {
    guest_cmd "$client_ssh_ip" \
        "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' '$requests' '$warmup'"
}

record_scenario() {
    local name=$1
    local result=$2
    local backend=$3
    local client_log=$4
    local server_log=$5
    {
        printf '### %s\n\n' "$name"
        printf 'client: `%s`\n\n' "$result"
        printf 'backend_requests: `%s`\n\n' "$backend"
        printf 'client_metrics: `%s`\n\n' "$(monitor_line "$client_log" "$client_ssh_ip")"
        printf 'server_metrics: `%s`\n\n' "$(monitor_line "$server_log" "$backend_ssh_ip")"
    } >> "$out_dir/summary.md"
}

run_scenario() {
    local name=$1
    stop_guest_processes
    start_backend
    start_monitor server "$name"
    start_monitor client "$name"
    local result
    if [[ "$name" == baseline ]]; then
        result=$(run_client)
    else
        result=$(run_client)
    fi
    printf '%s\n' "$result" > "$out_dir/${name}.client.log"
    sleep 1
    local count
    count=$(backend_count)
    guest_cmd "$client_ssh_ip" "cat /tmp/dns-client-monitor.log /tmp/dns-client-$name.log 2>/dev/null || true" > "$out_dir/${name}.client-monitor.log" || true
    guest_cmd "$backend_ssh_ip" "cat /tmp/dns-server-$name.log 2>/dev/null || true" > "$out_dir/${name}.server-monitor.log" || true
    printf '%s\n' "$count" > "$out_dir/${name}.backend-count"
    record_scenario "$name" "$result" "$count" "/tmp/dns-client-$name.log" "/tmp/dns-server-$name.log"
    stop_guest_processes
}

run_safety_checks() {
    stop_guest_processes
    start_backend 1
    start_monitor client ttl
    guest_cmd "$client_ssh_ip" "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' 1 1" > "$out_dir/ttl-hit.log" || true
    sleep 2
    guest_cmd "$client_ssh_ip" "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' 1 0" > "$out_dir/ttl-expired.log" || true
    printf 'ttl_backend_requests=%s\n' "$(backend_count)" | tee "$out_dir/ttl-summary.txt"
    [[ "$(backend_count)" == 2 ]] || { echo "TTL expiry check failed" >&2; return 1; }
    stop_guest_processes

    start_backend 60
    start_monitor client untrusted
    guest_cmd "$client_ssh_ip" "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' 2 0" > "$out_dir/untrusted.log" || true
    printf 'untrusted_backend_requests=%s\n' "$(backend_count)" | tee "$out_dir/untrusted-summary.txt"
    [[ "$(backend_count)" == 2 ]] || { echo "untrusted resolver check failed" >&2; return 1; }
    stop_guest_processes

    start_backend 60 nxdomain
    start_monitor client nxdomain
    guest_cmd "$client_ssh_ip" "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' 2 0" > "$out_dir/nxdomain.log" || true
    printf 'nxdomain_backend_requests=%s\n' "$(backend_count)" | tee "$out_dir/nxdomain-summary.txt"
    [[ "$(backend_count)" == 2 ]] || { echo "NXDOMAIN check failed" >&2; return 1; }
    stop_guest_processes
}

printf '# OpenStack DNS Dual-End Cache E2E\n\n' > "$out_dir/summary.md"
printf 'mode=guest-ebpf\nnetns=%s\nimage=%s\nflavor=%s\nnetwork=%s\nrequests=%s\nwarmup=%s\nrepeat=%s\n' \
    "${netns:-none}" "$image" "$flavor" "$network" "$requests" "$warmup" "$repeat" > "$out_dir/environment.md"
printf 'backend_interface=%s\nclient_interface=%s\n' "$backend_dev" "$client_dev" >> "$out_dir/environment.md"

for run_id in $(seq 1 "$repeat"); do
    printf '## Run %s\n\n' "$run_id" >> "$out_dir/summary.md"
    for scenario in baseline monitor-only server-only client-only both; do
        run_scenario "$scenario"
    done
done
run_safety_checks
printf 'artifact=%s\n' "$out_dir"
