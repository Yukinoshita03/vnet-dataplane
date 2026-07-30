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
run_id=vnet-migration-$(date +%s)-$$
client_run_dir=/tmp/$run_id
backend_run_dir=/tmp/$run_id
client_dns_harness=$client_run_dir/openstack_dns_harness
client_grpc_harness=$client_run_dir/openstack_grpc_harness
client_dns_probe_pid=$client_run_dir/dns-probe.pid
client_grpc_probe_pid=$client_run_dir/grpc-probe.pid
client_dns_probe_log=$client_run_dir/dns-probe.log
client_grpc_probe_log=$client_run_dir/grpc-probe.log
backend_dns_monitor=$backend_run_dir/dns_monitor
backend_dns_bpf=$backend_run_dir/dns_xdp_monitor.bpf.o
backend_grpc_harness=$backend_run_dir/openstack_grpc_harness
backend_grpc_cache=$backend_run_dir/grpc_fast_cache
backend_cachectl=$backend_run_dir/cachectl
backend_dns_pid_file=$backend_run_dir/dns-monitor.pid
backend_grpc_pid_file=$backend_run_dir/grpc-server.pid
backend_cache_pid_file=$backend_run_dir/grpc-cache.pid
backend_dns_log=$backend_run_dir/dns-monitor.log
backend_grpc_log=$backend_run_dir/grpc-backend.log
backend_cache_log=$backend_run_dir/grpc-cache.log
backend_policy=$backend_run_dir/migration-policy.txt
pin_dir=/sys/fs/bpf/$run_id-grpc
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
        "stop_pid_file() {
            pid_file=\$1
            [ -s \"\$pid_file\" ] || return 0
            read -r pid expected_start_time <\"\$pid_file\"
            case \"\$pid:\$expected_start_time\" in
                *[!0-9:]*|:*|*:) echo \"invalid probe process identity: \$pid_file\" >&2; return 1 ;;
            esac
            if ! kill -0 \"\$pid\" 2>/dev/null; then
                if kill -0 -- \"-\$pid\" 2>/dev/null; then
                    echo \"probe leader \$pid exited while its process group remains\" >&2
                    return 1
                fi
                rm -f \"\$pid_file\"
                return 0
            fi
            current_start_time=\$(awk '{print \$22}' \"/proc/\$pid/stat\" 2>/dev/null)
            pgid=\$(ps -o pgid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]')
            sid=\$(ps -o sid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]')
            if [ \"\$current_start_time\" != \"\$expected_start_time\" ] ||
                [ \"\$pgid\" != \"\$pid\" ] || [ \"\$sid\" != \"\$pid\" ]; then
                echo \"refusing to signal probe without its recorded process group: \$pid\" >&2
                return 1
            fi
            kill -TERM -- \"-\$pid\" 2>/dev/null || true
            for _ in \$(seq 1 50); do
                kill -0 -- \"-\$pid\" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 -- \"-\$pid\" 2>/dev/null; then
                echo \"probe process group \$pid did not stop gracefully\" >&2
                kill -KILL -- \"-\$pid\" 2>/dev/null || true
            fi
            if kill -0 -- \"-\$pid\" 2>/dev/null; then
                echo \"probe process group \$pid survived KILL\" >&2
                return 1
            fi
            rm -f \"\$pid_file\"
        }
        status=0
        stop_pid_file '$client_dns_probe_pid' || status=1
        stop_pid_file '$client_grpc_probe_pid' || status=1
        exit \"\$status\""
}

collect_probe_logs() {
    guest_cmd "$client_ip" "cat '$client_dns_probe_log' 2>/dev/null || true" \
        > "$out_dir/dns-probe.log" || true
    guest_cmd "$client_ip" "cat '$client_grpc_probe_log' 2>/dev/null || true" \
        > "$out_dir/grpc-probe.log" || true
}

stop_backend_services() {
    guest_cmd "$backend_ip" \
        "stop_pid_file() {
            pid_file=\$1
            [ -s \"\$pid_file\" ] || return 0
            read -r pid expected_start_time <\"\$pid_file\"
            case \"\$pid:\$expected_start_time\" in
                *[!0-9:]*|:*|*:) echo \"invalid backend process identity: \$pid_file\" >&2; return 1 ;;
            esac
            if ! sudo -n kill -0 \"\$pid\" 2>/dev/null; then
                if sudo -n kill -0 -- \"-\$pid\" 2>/dev/null; then
                    echo \"backend leader \$pid exited while its process group remains\" >&2
                    return 1
                fi
                rm -f \"\$pid_file\"
                return 0
            fi
            current_start_time=\$(sudo -n awk '{print \$22}' \"/proc/\$pid/stat\" 2>/dev/null)
            pgid=\$(sudo -n ps -o pgid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]')
            sid=\$(sudo -n ps -o sid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]')
            if [ \"\$current_start_time\" != \"\$expected_start_time\" ] ||
                [ \"\$pgid\" != \"\$pid\" ] || [ \"\$sid\" != \"\$pid\" ]; then
                echo \"refusing to signal backend process without its recorded group: \$pid\" >&2
                return 1
            fi
            sudo -n kill -TERM -- \"-\$pid\" 2>/dev/null || true
            for _ in \$(seq 1 50); do
                sudo -n kill -0 -- \"-\$pid\" 2>/dev/null || break
                sleep 0.1
            done
            if sudo -n kill -0 -- \"-\$pid\" 2>/dev/null; then
                echo \"backend process group \$pid did not stop gracefully\" >&2
                sudo -n kill -KILL -- \"-\$pid\" 2>/dev/null || true
            fi
            if sudo -n kill -0 -- \"-\$pid\" 2>/dev/null; then
                echo \"backend process group \$pid survived KILL\" >&2
                return 1
            fi
            rm -f \"\$pid_file\"
        }
        status=0
        stop_pid_file '$backend_dns_pid_file' || status=1
        stop_pid_file '$backend_grpc_pid_file' || status=1
        stop_pid_file '$backend_cache_pid_file' || status=1
        exit \"\$status\""
}

cleanup_guests() {
    local probes_clean=$1
    local lifecycle_failed=0

    [[ "$probes_clean" == 1 ]] || lifecycle_failed=1
    stop_backend_services || lifecycle_failed=1
    if (( lifecycle_failed == 0 )); then
        guest_cmd "$client_ip" "rm -rf -- '$client_run_dir'" || lifecycle_failed=1
        guest_cmd "$backend_ip" \
            "sudo -n rm -rf -- '$pin_dir'; rm -rf -- '$backend_run_dir'" || lifecycle_failed=1
    else
        echo "preserving guest run directories and pin path after lifecycle validation failure" >&2
    fi
    return "$lifecycle_failed"
}

cleanup() {
    local status=$?
    local lifecycle_failed=0
    local probes_clean=0
    local current_host reset_host
    trap - EXIT
    set +e
    if stop_probes; then
        probes_clean=1
    else
        lifecycle_failed=1
    fi
    collect_probe_logs
    current_host=$(server_host 2>/dev/null) || current_host=""
    if [[ -z "$current_host" ]]; then
        echo "could not verify backend placement during cleanup" >&2
        lifecycle_failed=1
    elif [[ "$current_host" == "$target_host" ]]; then
        if bash "$reset_runner" --vm-id "$backend_id" \
            --expected-source "$target_host" --target-host "$source_host" \
            --run-dir "$out_dir/reset-from-trap" --disk-overcommit \
            --timeout-seconds 900 --poll-seconds 5; then
            reset_host=$(server_host 2>/dev/null) || reset_host=""
            if [[ "$reset_host" != "$source_host" ]]; then
                echo "backend did not return to $source_host during cleanup: ${reset_host:-unknown}" >&2
                lifecycle_failed=1
            fi
        else
            lifecycle_failed=1
        fi
    elif [[ "$current_host" != "$source_host" ]]; then
        echo "backend is on unexpected host during cleanup: $current_host" >&2
        lifecycle_failed=1
    fi
    cleanup_guests "$probes_clean" || lifecycle_failed=1
    if (( lifecycle_failed != 0 )); then
        [[ "$status" -ne 0 ]] || status=1
    fi
    {
        echo "lifecycle_failed=$lifecycle_failed"
        echo "client_probe_cleanup=$probes_clean"
        echo "client_run_dir=$client_run_dir"
        echo "backend_run_dir=$backend_run_dir"
        echo "backend_pin_dir=$pin_dir"
        echo "reset_source_host=${current_host:-unknown}"
    } > "$out_dir/cleanup-audit.txt"
    rm -f "$askpass"
    printf 'cleanup_status=%s\ncleanup_lifecycle_failed=%s\n' \
        "$status" "$lifecycle_failed" > "$out_dir/cleanup-status.txt"
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

guest_cmd "$client_ip" "mkdir -p '$client_run_dir'"
guest_cmd "$backend_ip" "mkdir -p '$backend_run_dir'"
copy_guest "$client_ip" "$dns_harness" "$client_dns_harness"
copy_guest "$client_ip" "$grpc_harness" "$client_grpc_harness"
copy_guest "$backend_ip" "$dns_monitor" "$backend_dns_monitor"
copy_guest "$backend_ip" "$dns_bpf" "$backend_dns_bpf"
copy_guest "$backend_ip" "$grpc_harness" "$backend_grpc_harness"
copy_guest "$backend_ip" "$grpc_cache" "$backend_grpc_cache"
copy_guest "$backend_ip" "$cachectl" "$backend_cachectl"

guest_cmd "$backend_ip" \
    "record_process_group() {
    pid=\$1
    pid_file=\$2
    start_time=\$(sudo -n awk '{print \$22}' \"/proc/\$pid/stat\" 2>/dev/null)
    pgid=\$(sudo -n ps -o pgid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]')
    sid=\$(sudo -n ps -o sid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]')
    case \"\$pid:\$start_time\" in
        *[!0-9:]*|:*|*:) return 1 ;;
    esac
    [ \"\$pgid\" = \"\$pid\" ] && [ \"\$sid\" = \"\$pid\" ] || return 1
    printf '%s %s\n' \"\$pid\" \"\$start_time\" >\"\$pid_file\"
}
sudo -n mkdir -p /sys/fs/bpf
mountpoint -q /sys/fs/bpf || sudo -n mount -t bpf bpf /sys/fs/bpf
sudo -n rm -rf -- '$pin_dir'
sudo -n mkdir -p '$pin_dir'
setsid nohup sudo -n '$backend_dns_monitor' --dev ens3 --hook xdp --role server --xdp-mode generic --bpf-object '$backend_dns_bpf' --cache-domain '$domain' --cache-ip '$answer_ip' --cache-ttl 600 --verbose-events >'$backend_dns_log' 2>&1 </dev/null &
record_process_group \$! '$backend_dns_pid_file' || exit 1
setsid nohup sudo -n '$backend_grpc_harness' server '$backend_ip' 50051 300 >'$backend_grpc_log' 2>&1 </dev/null &
record_process_group \$! '$backend_grpc_pid_file' || exit 1
sudo -n '$backend_grpc_harness' seed '$pin_dir/grpc_policy_map'
sudo -n '$backend_grpc_harness' seed-response '$pin_dir/grpc_response_cache' '$payload' SERVING 600
cat >'$backend_policy' <<EOF
grpc $method 600 idempotent
grpc-cache $method $payload SERVING 600
EOF
sudo -n '$backend_cachectl' --policy-file '$backend_policy' --grpc-map '$pin_dir/grpc_policy_map' --grpc-response-map '$pin_dir/grpc_response_cache' --replace
setsid nohup sudo -n '$backend_grpc_cache' --grpc-map '$pin_dir/grpc_policy_map' --grpc-response-map '$pin_dir/grpc_response_cache' --listen '$backend_ip':50052 --backend '$backend_ip':50051 --method '$method' --verbose >'$backend_cache_log' 2>&1 </dev/null &
record_process_group \$! '$backend_cache_pid_file' || exit 1"
sleep 3

guest_cmd "$backend_ip" \
    "hostname
for pid_file in '$backend_dns_pid_file' '$backend_grpc_pid_file' '$backend_cache_pid_file'; do
    [ -s \"\$pid_file\" ] && ps -fp \"\$(awk '{print \$1}' \"\$pid_file\")\" || true
done
sudo -n bpftool net show dev ens3
sudo -n bpftool map show pinned '$pin_dir/grpc_response_cache'
ss -lunp | grep ':53 ' || true
ss -ltnp | grep -E ':5005[12] ' || true" > "$out_dir/backend-before.txt"

guest_cmd "$client_ip" \
    "record_process_group() {
    pid=\$1
    pid_file=\$2
    start_time=\$(awk '{print \$22}' \"/proc/\$pid/stat\" 2>/dev/null)
    pgid=\$(ps -o pgid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]')
    sid=\$(ps -o sid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]')
    case \"\$pid:\$start_time\" in
        *[!0-9:]*|:*|*:) return 1 ;;
    esac
    [ \"\$pgid\" = \"\$pid\" ] && [ \"\$sid\" = \"\$pid\" ] || return 1
    printf '%s %s\n' \"\$pid\" \"\$start_time\" >\"\$pid_file\"
}
setsid nohup bash -c 'for i in \$(seq 1 \"\$6\"); do printf \"ts_ms=%s \" \"\$(date +%s%3N)\"; \"\$1\" client \"\$2\" 53 \"\$3\" \"\$4\" 20 0; sleep \"\$5\"; done' _ '$client_dns_harness' '$backend_ip' '$domain' '$answer_ip' '$probe_pause' '$probe_iterations' >'$client_dns_probe_log' 2>&1 </dev/null &
dns_job=\$!
record_process_group \"\$dns_job\" '$client_dns_probe_pid' || exit 1
setsid nohup bash -c 'for i in \$(seq 1 \"\$5\"); do printf \"ts_ms=%s \" \"\$(date +%s%3N)\"; \"\$1\" client \"\$2\" 50052 20 0 \"\$3\"; sleep \"\$4\"; done' _ '$client_grpc_harness' '$backend_ip' '$payload' '$probe_pause' '$probe_iterations' >'$client_grpc_probe_log' 2>&1 </dev/null &
grpc_job=\$!
record_process_group \"\$grpc_job\" '$client_grpc_probe_pid' || exit 1"
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
