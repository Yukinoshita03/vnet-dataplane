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
availability_zone=${AVAILABILITY_ZONE:-}
floating_network=${FLOATING_NETWORK:-public}
use_floating_ip=${USE_FLOATING_IP:-1}
floating_cidr=${FLOATING_CIDR:-172.24.4.0/24}
netns=${NETNS:-auto}
key_name=${KEY_NAME:-}
guest_key=${GUEST_KEY:-}
temporary_key_name=
guest_user=${GUEST_USER:-ubuntu}
requests=${REQUESTS:-1000}
warmup=${WARMUP:-100}
repeat=${REPEAT:-5}
domain=${DOMAIN:-example.test}
answer_ip=${ANSWER_IP:-10.0.0.123}
backend_ttl=${BACKEND_TTL_SEC:-60}
guest_bpf=${GUEST_BPF:-1}
ssh_wait_attempts=${SSH_WAIT_ATTEMPTS:-450}
ssh_ready_timeout=${SSH_READY_TIMEOUT_SEC:-$((ssh_wait_attempts * 2))}
ssh_probe_timeout=${SSH_PROBE_TIMEOUT_SEC:-8}
ssh_command_timeout=${SSH_COMMAND_TIMEOUT_SEC:-45}
keep_resources=${KEEP_RESOURCES:-0}
existing_client_server=${CLIENT_SERVER:-}
existing_backend_server=${BACKEND_SERVER:-}
require_tc_coexistence=${REQUIRE_TC_COEXISTENCE:-0}
sudo_password=${SUDO_PASS:-}
sudo_askpass=

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
client_port_id=
client_tap_if=
client_cache_mode=guest-ebpf
owns_servers=1
security_group_id=
floating_ip_ids=()
monitor_pids=()
client_host_monitor_pid=
mkdir -p "$out_dir"
if [[ -n "$sudo_password" ]]; then
    sudo_askpass="$out_dir/.sudo-askpass"
    printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$SUDO_PASS"' > "$sudo_askpass"
    chmod 700 "$sudo_askpass"
fi
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
sudo_stream_cmd() {
    if [[ -n "$sudo_password" ]]; then
        SUDO_ASKPASS="$sudo_askpass" SUDO_PASS="$sudo_password" sudo -A "$@"
    else
        sudo "$@"
    fi
}
host_root_cmd() {
    if [[ -n "$sudo_password" ]]; then
        printf '%s\n' "$sudo_password" | sudo -S -p '' bash -c "$1"
    else
        sudo bash -c "$1"
    fi
}
guest_opts=(-i "$guest_key" -o BatchMode=yes -o ConnectTimeout=8
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3
    -o ControlMaster=no)

ssh_guest_with_timeout() {
    local timeout_seconds=$1
    shift
    local ip=$1
    shift
    if [[ -n "$netns" ]]; then
        sudo_cmd timeout "$timeout_seconds" ip netns exec "$netns" \
            ssh "${guest_opts[@]}" "$guest_user@$ip" "$@"
    else
        timeout "$timeout_seconds" ssh "${guest_opts[@]}" "$guest_user@$ip" "$@"
    fi
}

ssh_guest() {
    ssh_guest_with_timeout "$ssh_command_timeout" "$@"
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
        gzip -1c "$source_file" | base64 | tr -d '\n' | sudo_stream_cmd ip netns exec "$netns" \
            ssh "${guest_opts[@]}" "$guest_user@$ip" \
            "base64 -d | gzip -d > '$target_file' && chmod +x '$target_file'"
    else
        gzip -1c "$source_file" | base64 | tr -d '\n' | ssh "${guest_opts[@]}" \
            "$guest_user@$ip" "base64 -d | gzip -d > '$target_file' && chmod +x '$target_file'"
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
    local args=(server create --wait
        --image "$image" --flavor "$flavor" --network "$network"
        --security-group "$security_group_id" --key-name "$key_name")
    if [[ -n "$availability_zone" ]]; then
        args+=(--availability-zone "$availability_zone")
    fi
    args+=("$1" -f value -c id)
    openstack_cmd "${args[@]}"
}

backend_count() {
    guest_cmd "$backend_ssh_ip" "test -s /tmp/dns-backend-count && tail -n 1 /tmp/dns-backend-count | tr -d '[:space:]' || printf 0"
}

stop_host_monitor() {
    local pid=$1
    [[ -n "$pid" ]] || return 0
    [[ "$pid" =~ ^[0-9]+$ ]] || {
        echo "invalid monitor pid: $pid" >&2
        return 1
    }
    # Monitors are started under setsid, so stop their private process group
    # before falling back to the wrapper PID.
    sudo_cmd kill -TERM -- "-$pid" >/dev/null 2>&1 || \
        sudo_cmd kill -TERM "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        sudo_cmd kill -0 "$pid" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    echo "monitor pid $pid did not stop gracefully; refusing blind hook cleanup" >&2
    sudo_cmd kill -KILL -- "-$pid" >/dev/null 2>&1 || \
        sudo_cmd kill -KILL "$pid" >/dev/null 2>&1 || true
}

stop_guest_processes() {
    if [[ -n "$client_host_monitor_pid" ]]; then
        stop_host_monitor "$client_host_monitor_pid"
        client_host_monitor_pid=
    fi
    guest_root_cmd "$backend_ssh_ip" 'stop_pid_file() {
        [ -s "$1" ] || return 0
        pid="$(cat "$1")"
        case "$pid" in
            *[!0-9]*|"") echo "invalid monitor pid: $pid" >&2; return 1 ;;
        esac
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        for i in $(seq 1 50); do
            kill -0 "$pid" 2>/dev/null || return 0
            sleep 0.1
        done
        echo "monitor pid $pid did not stop gracefully; refusing blind hook cleanup" >&2
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    }
    stop_pid_file /tmp/dns-backend.pid
    stop_pid_file /tmp/dns-server-monitor.pid
    rm -f /tmp/dns-backend.pid /tmp/dns-server-monitor.pid /tmp/dns-backend-count' || true
    guest_root_cmd "$client_ssh_ip" 'if [ -s /tmp/dns-client-monitor.pid ]; then
        pid="$(cat /tmp/dns-client-monitor.pid)"
        case "$pid" in
            *[!0-9]*|"") echo "invalid monitor pid: $pid" >&2; return 1 ;;
        esac
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        for i in $(seq 1 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo "monitor pid $pid did not stop gracefully; refusing blind hook cleanup" >&2
            kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    rm -f /tmp/dns-client-monitor.pid' || true
}

cleanup() {
    local status=$?
    set +e
    if [[ -n "$backend_ssh_ip" && -n "$client_ssh_ip" ]]; then
        stop_guest_processes
        guest_root_cmd "$client_ssh_ip" \
            'rm -f /tmp/openstack_dns_harness /tmp/dns_monitor /tmp/dns_client_cache.bpf.o /tmp/dns_monitor.bpf.o'
        guest_root_cmd "$backend_ssh_ip" \
            'rm -f /tmp/openstack_dns_harness /tmp/dns_monitor /tmp/dns_xdp_monitor.bpf.o /tmp/dns_monitor.bpf.o'
    fi
    if [[ "$keep_resources" != 1 ]]; then
        if [[ "$owns_servers" == 1 ]]; then
            [[ -n "$backend_id" ]] && openstack_cmd server delete --wait "$backend_id" >/dev/null 2>&1 || true
            [[ -n "$client_id" ]] && openstack_cmd server delete --wait "$client_id" >/dev/null 2>&1 || true
        fi
        for id in "${floating_ip_ids[@]}"; do
            [[ -n "$id" ]] && openstack_cmd floating ip delete "$id" >/dev/null 2>&1 || true
        done
        [[ -n "$security_group_id" ]] && openstack_cmd security group delete "$security_group_id" >/dev/null 2>&1 || true
        [[ -n "$temporary_key_name" ]] && openstack_cmd keypair delete "$temporary_key_name" >/dev/null 2>&1 || true
    else
        echo "KEEP_RESOURCES=1; temporary servers and network resources preserved"
    fi
    if [[ "$status" -ne 0 ]]; then
        echo "benchmark failed with exit=$status"
        openstack_cmd server list --name "$prefix" -f value -c ID -c Name -c Status || true
    fi
    printf 'cleanup_status=%s\n' "$status" > "$out_dir/cleanup-status.txt"
    [[ -n "$sudo_askpass" ]] && rm -f "$sudo_askpass"
    exit "$status"
}
trap cleanup EXIT

for command in openstack ssh ssh-keygen base64 gzip awk grep ip python3 gcc c++ timeout sudo; do need "$command"; done
[[ -f "$openrc" ]] || { echo "missing openrc: $openrc" >&2; exit 1; }
# shellcheck disable=SC1090
set +u
source "$openrc" "$openrc_user" "$openrc_project"
set -u
openstack_cmd token issue -f value -c id >/dev/null
if [[ -z "$key_name" ]]; then
    key_name="$prefix-key"
    temporary_key_name=$key_name
    key_public_file="$out_dir/guest-key.pub"
    ssh-keygen -y -f "$guest_key" > "$key_public_file"
    openstack_cmd keypair create --public-key "$key_public_file" "$key_name" >/dev/null
fi
if [[ "$netns" == auto ]]; then
    # Listing namespaces is unprivileged on the DevStack host.  Keeping this
    # outside sudo avoids an inherited SUDO_PASS/pipe interaction selecting no
    # namespace and then trying to reach floating IPs from the wrong context.
    netns=$(ip netns list | awk '/^ovnmeta-/{print $1; exit}')
fi
[[ "$netns" == none ]] && netns=
printf 'netns=%s\n' "${netns:-none}" > "$out_dir/environment.md"
[[ "$guest_bpf" == 0 || "$guest_bpf" == 1 ]] || {
    echo "GUEST_BPF must be 0 or 1" >&2
    exit 1
}
if [[ -n "$existing_client_server" || -n "$existing_backend_server" ]]; then
    [[ -n "$existing_client_server" && -n "$existing_backend_server" ]] || {
        echo "CLIENT_SERVER and BACKEND_SERVER must be set together" >&2
        exit 1
    }
fi

if [[ -n "$existing_client_server" ]]; then
    client_id=$(openstack_cmd server show "$existing_client_server" -f value -c id)
    backend_id=$(openstack_cmd server show "$existing_backend_server" -f value -c id)
    owns_servers=0
else
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
fi
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
client_port_id=$(openstack_cmd port list --server "$client_id" -f value -c ID | head -n 1)
client_tap_if="tap$(printf '%s' "$client_port_id" | cut -c1-11)"
if ip link show "$client_tap_if" >/dev/null 2>&1 && [[ -f "$accel_dir/build/dns_client_cache.bpf.o" ]]; then
    client_cache_mode=host-ebpf
fi

for endpoint in "$client_ssh_ip" "$backend_ssh_ip"; do
    ready=0
    ready_deadline=$((SECONDS + ssh_ready_timeout))
    while (( SECONDS < ready_deadline )); do
        if ssh_guest_with_timeout "$ssh_probe_timeout" "$endpoint" \
            true >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 2
    done
    [[ "$ready" == 1 ]] || { echo "SSH timeout: $endpoint" >&2; exit 1; }
done

for endpoint in "$client_ssh_ip" "$backend_ssh_ip"; do
    guest_root_cmd "$endpoint" 'host=$(hostname); grep -q "[[:space:]]$host\([[:space:]]\|$\)" /etc/hosts || printf "127.0.1.1 %s\n" "$host" >> /etc/hosts'
done
guest_root_cmd "$client_ssh_ip" 'sudo -n true; ip route show default; uname -a; mkdir -p /sys/fs/bpf; mountpoint -q /sys/fs/bpf || timeout 10 mount -t bpf bpf /sys/fs/bpf'
guest_root_cmd "$backend_ssh_ip" 'sudo -n true; ip route show default; uname -a; mkdir -p /sys/fs/bpf; mountpoint -q /sys/fs/bpf || timeout 10 mount -t bpf bpf /sys/fs/bpf'
client_dev=$(guest_cmd "$client_ssh_ip" "ip route show default | awk 'NR==1{print \$5}'")
backend_dev=$(guest_cmd "$backend_ssh_ip" "ip route show default | awk 'NR==1{print \$5}'")
printf 'client_dev=%s backend_dev=%s client_tap=%s client_cache_mode=%s guest_bpf=%s\n' \
    "$client_dev" "$backend_dev" "$client_tap_if" "$client_cache_mode" "$guest_bpf" >> "$out_dir/topology.txt"
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
    guest_root_cmd "$client_ssh_ip" 'mountpoint -q /sys/fs/bpf || timeout 10 mount -t bpf bpf /sys/fs/bpf'
    guest_root_cmd "$backend_ssh_ip" 'mountpoint -q /sys/fs/bpf || timeout 10 mount -t bpf bpf /sys/fs/bpf'
fi

start_backend() {
    local ttl=${1:-$backend_ttl}
    local mode=${2:-a}
    local mode_arg=
    [[ "$mode" == nxdomain ]] && mode_arg=nxdomain
    guest_root_cmd "$backend_ssh_ip" \
        "rm -f /tmp/dns-backend-count /tmp/dns-backend.pid; nohup /tmp/openstack_dns_harness server 0.0.0.0 53 '$domain' '$answer_ip' '$ttl' /tmp/dns-backend-count '$mode_arg' >/tmp/dns-backend.log 2>&1 </dev/null & echo \$! >/tmp/dns-backend.pid"
    sleep 1
    guest_root_cmd "$backend_ssh_ip" 'test -s /tmp/dns-backend.pid && kill -0 "$(cat /tmp/dns-backend.pid)"'
}

start_monitor() {
    local side=$1
    local scenario=$2
    local log=/tmp/dns-${side}-${scenario}.log
    if [[ "$side" == server ]]; then
        if [[ "$scenario" == server-only || "$scenario" == both ]]; then
            guest_root_cmd "$backend_ssh_ip" \
                "setsid nohup timeout 90 /tmp/dns_monitor --dev '$backend_dev' --hook xdp --role server --xdp-mode generic --bpf-object /tmp/dns_xdp_monitor.bpf.o --cache-domain '$domain' --cache-ip '$answer_ip' --cache-ttl '$backend_ttl' --verbose-events >'$log' 2>&1 </dev/null & echo \$! >/tmp/dns-server-monitor.pid"
        elif [[ "$scenario" == monitor-only ]]; then
            guest_root_cmd "$backend_ssh_ip" \
                "setsid nohup timeout 90 /tmp/dns_monitor --dev '$backend_dev' --hook tc --bpf-object /tmp/dns_monitor.bpf.o --verbose-events >'$log' 2>&1 </dev/null & echo \$! >/tmp/dns-server-monitor.pid"
        fi
    else
        if [[ "$scenario" == client-only || "$scenario" == both || "$scenario" == ttl || "$scenario" == untrusted || "$scenario" == nxdomain ]]; then
            local trusted=$backend_ip
            [[ "$scenario" == untrusted ]] && trusted=10.254.254.254
            if [[ "$client_cache_mode" == host-ebpf ]]; then
                local host_log="$out_dir/${scenario}.client-host.log"
                local host_cmd="setsid timeout 90 '$dns_monitor' --dev '$client_tap_if' --hook xdp --role client --xdp-mode generic --bpf-object '$accel_dir/build/dns_client_cache.bpf.o' --max-learn-ttl 300 --learn-window-ms 2000 --trusted-dns '$trusted' --verbose-events >'$host_log' 2>&1 </dev/null & echo \$!"
                client_host_monitor_pid=$(host_root_cmd "$host_cmd" | tail -n 1)
                sleep 2
                return
            fi
            guest_root_cmd "$client_ssh_ip" \
                "setsid nohup timeout 90 /tmp/dns_monitor --dev '$client_dev' --hook xdp --role client --xdp-mode generic --bpf-object /tmp/dns_client_cache.bpf.o --max-learn-ttl 300 --learn-window-ms 2000 --trusted-dns '$trusted' --verbose-events >'$log' 2>&1 </dev/null & echo \$! >/tmp/dns-client-monitor.pid"
        fi
    fi
    sleep 2
}

monitor_line() {
    local log=$1
    local active_metrics='qps=[1-9]|rps=[1-9]|cache_hit=[1-9]|cache_learned=[1-9]|cache_tx=[1-9]'
    if [[ "$2" == host ]]; then
        [[ -f "$log" ]] || return 0
        grep 'dns_metrics' "$log" 2>/dev/null | grep -E "$active_metrics" | tail -n 1 ||
            grep 'dns_metrics' "$log" 2>/dev/null | tail -n 1 || true
    else
        guest_cmd "$2" "grep 'dns_metrics' '$log' | grep -E '$active_metrics' | tail -n 1 || grep 'dns_metrics' '$log' | tail -n 1" 2>/dev/null || true
    fi
}

verify_client_tc_coexistence() {
    local scenario=$1
    [[ "$require_tc_coexistence" == 1 ]] || return 0
    local ingress_log="$out_dir/${scenario}.tc-ingress.txt"
    local egress_log="$out_dir/${scenario}.tc-egress.txt"
    local dns_line netmig_line

    sudo_cmd tc filter show dev "$client_tap_if" ingress > "$ingress_log"
    sudo_cmd tc filter show dev "$client_tap_if" egress > "$egress_log"
    dns_line=$(grep -n 'handle 0x1 ' "$ingress_log" | head -n 1 | cut -d: -f1 || true)
    netmig_line=$(grep -n 'handle 0x65 ' "$ingress_log" | head -n 1 | cut -d: -f1 || true)
    [[ -n "$dns_line" && -n "$netmig_line" && "$dns_line" -lt "$netmig_line" ]] || {
        echo "$scenario ingress TC coexistence order is invalid" >&2
        return 1
    }
    dns_line=$(grep -n 'handle 0x1 ' "$egress_log" | head -n 1 | cut -d: -f1 || true)
    netmig_line=$(grep -n 'handle 0x66 ' "$egress_log" | head -n 1 | cut -d: -f1 || true)
    [[ -n "$dns_line" && -n "$netmig_line" && "$dns_line" -lt "$netmig_line" ]] || {
        echo "$scenario egress TC coexistence order is invalid" >&2
        return 1
    }
}

run_client() {
    guest_cmd "$client_ssh_ip" \
        "timeout 120 /tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' '$requests' '$warmup'"
}

record_scenario() {
    local name=$1
    local result=$2
    local backend=$3
    local client_log=$4
    local server_log=$5
    local client_target=${6:-$client_ssh_ip}
    {
        printf '### %s\n\n' "$name"
        printf 'client: `%s`\n\n' "$result"
        printf 'backend_requests: `%s`\n\n' "$backend"
        printf 'client_metrics: `%s`\n\n' "$(monitor_line "$client_log" "$client_target")"
        printf 'server_metrics: `%s`\n\n' "$(monitor_line "$server_log" "$backend_ssh_ip")"
    } >> "$out_dir/summary.md"
}

run_scenario() {
    local name=$1
    stop_guest_processes
    start_backend
    start_monitor server "$name"
    start_monitor client "$name"
    if [[ "$name" == client-only || "$name" == both ]]; then
        verify_client_tc_coexistence "$name"
    fi
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
    printf '%s\n' "$count" > "$out_dir/${name}.backend-count"
    case "$name" in
        baseline|monitor-only) [[ "$count" == "$((requests + warmup))" ]] || { echo "$name backend count contaminated: $count" >&2; return 1; } ;;
        server-only|both) [[ "$count" == 0 ]] || { echo "$name backend count expected 0, got $count" >&2; return 1; } ;;
        client-only) [[ "$count" == 1 ]] || { echo "client-only backend count expected 1, got $count" >&2; return 1; } ;;
    esac
    # dns_monitor emits its final aggregate when SIGTERM is handled.  Stop it
    # before copying the logs so the artifacts contain cache learn/hit/tx data.
    stop_guest_processes
    local client_metrics_log=/tmp/dns-client-$name.log
    local client_metrics_target=$client_ssh_ip
    if [[ "$client_cache_mode" == host-ebpf ]]; then
        client_metrics_log="$out_dir/${name}.client-host.log"
        client_metrics_target=host
        cp "$client_metrics_log" "$out_dir/${name}.client-monitor.log" 2>/dev/null || true
    else
        guest_cmd "$client_ssh_ip" "cat /tmp/dns-client-monitor.log /tmp/dns-client-$name.log 2>/dev/null || true" > "$out_dir/${name}.client-monitor.log" || true
    fi
    guest_cmd "$backend_ssh_ip" "cat /tmp/dns-server-$name.log 2>/dev/null || true" > "$out_dir/${name}.server-monitor.log" || true
    record_scenario "$name" "$result" "$count" "$client_metrics_log" "/tmp/dns-server-$name.log" "$client_metrics_target"
}

run_safety_checks() {
    stop_guest_processes
    start_backend 1
    start_monitor client ttl
    verify_client_tc_coexistence ttl
    guest_cmd "$client_ssh_ip" "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' 1 1" > "$out_dir/ttl-hit.log" || true
    sleep 2
    guest_cmd "$client_ssh_ip" "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' 1 0" > "$out_dir/ttl-expired.log" || true
    local count
    count=$(backend_count) || { echo "TTL backend count read failed" >&2; return 1; }
    printf 'ttl_backend_requests=%s\n' "$count" | tee "$out_dir/ttl-summary.txt"
    # The warmup request seeds the cache, the measured request hits it, and the
    # post-expiry request goes back to the backend: exactly two backend hits.
    [[ "$count" == 2 ]] || { echo "TTL expiry check failed: $count" >&2; return 1; }
    stop_guest_processes

    start_backend 60
    start_monitor client untrusted
    verify_client_tc_coexistence untrusted
    guest_cmd "$client_ssh_ip" "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' 2 0" > "$out_dir/untrusted.log" || true
    count=$(backend_count) || { echo "untrusted backend count read failed" >&2; return 1; }
    printf 'untrusted_backend_requests=%s\n' "$count" | tee "$out_dir/untrusted-summary.txt"
    [[ "$count" == 2 ]] || { echo "untrusted resolver check failed: $count" >&2; return 1; }
    stop_guest_processes

    start_backend 60 nxdomain
    start_monitor client nxdomain
    verify_client_tc_coexistence nxdomain
    guest_cmd "$client_ssh_ip" "/tmp/openstack_dns_harness client '$backend_ip' 53 '$domain' '$answer_ip' 2 0" > "$out_dir/nxdomain.log" || true
    count=$(backend_count) || { echo "NXDOMAIN backend count read failed" >&2; return 1; }
    printf 'nxdomain_backend_requests=%s\n' "$count" | tee "$out_dir/nxdomain-summary.txt"
    [[ "$count" == 2 ]] || { echo "NXDOMAIN check failed: $count" >&2; return 1; }
    stop_guest_processes
}

printf '# OpenStack DNS Dual-End Cache E2E\n\n' > "$out_dir/summary.md"
printf 'mode=%s\nguest_bpf_requested=%s\nnetns=%s\nimage=%s\nflavor=%s\nnetwork=%s\nrequests=%s\nwarmup=%s\nrepeat=%s\n' \
    "$client_cache_mode" "$guest_bpf" "${netns:-none}" "$image" "$flavor" "$network" "$requests" "$warmup" "$repeat" > "$out_dir/environment.md"
printf 'backend_interface=%s\nclient_interface=%s\nclient_tap=%s\nclient_cache_mode=%s\n' \
    "$backend_dev" "$client_dev" "$client_tap_if" "$client_cache_mode" >> "$out_dir/environment.md"

for run_id in $(seq 1 "$repeat"); do
    printf '## Run %s\n\n' "$run_id" >> "$out_dir/summary.md"
    for scenario in baseline monitor-only server-only client-only both; do
        run_scenario "$scenario"
    done
done
run_safety_checks
printf 'artifact=%s\n' "$out_dir"
