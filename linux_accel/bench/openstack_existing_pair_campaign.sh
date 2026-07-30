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
dns_start_time=
grpc_pid=
grpc_start_time=
run_id=vnet-five-experiments-$(date +%s)-$$
client_run_dir=/tmp/$run_id
backend_run_dir=/tmp/$run_id
client_dns_harness=$client_run_dir/openstack_dns_harness
client_grpc_harness=$client_run_dir/openstack_grpc_harness
client_dns_pid_file=$client_run_dir/mixed-dns.pid
client_grpc_pid_file=$client_run_dir/mixed-grpc.pid
backend_dns_harness=$backend_run_dir/openstack_dns_harness
backend_grpc_harness=$backend_run_dir/openstack_grpc_harness
backend_grpc_cache=$backend_run_dir/grpc_fast_cache
backend_cachectl=$backend_run_dir/cachectl
backend_dns_pid_file=$backend_run_dir/dns-server.pid
backend_grpc_pid_file=$backend_run_dir/grpc-server.pid
backend_cache_pid_file=$backend_run_dir/grpc-cache.pid
backend_dns_log=$backend_run_dir/dns-backend.log
backend_grpc_log=$backend_run_dir/grpc-backend.log
backend_cache_log=$backend_run_dir/grpc-cache.log
backend_dns_count=$backend_run_dir/dns-backend-count
backend_policy=$backend_run_dir/grpc-policy.txt
backend_dynamic_policy=$backend_run_dir/grpc-dynamic.txt
pin_dir=/sys/fs/bpf/$run_id-grpc
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

host_process_start_time() {
    local pid=$1
    local start_time
    local pgid
    local sid

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    start_time=$(sudo_cmd awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
    pgid=$(sudo_cmd ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    sid=$(sudo_cmd ps -o sid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [[ "$start_time" =~ ^[0-9]+$ && "$pgid" == "$pid" && "$sid" == "$pid" ]] ||
        return 1
    printf '%s\n' "$start_time"
}

host_process_group_state() {
    local pgid=$1
    local process_groups

    [[ "$pgid" =~ ^[0-9]+$ ]] || return 2
    if sudo_cmd kill -0 -- "-$pgid" >/dev/null 2>&1; then
        return 0
    fi
    process_groups=$(sudo_cmd ps -eo pgid= 2>/dev/null) || {
        echo "failed to inspect recorded host process group $pgid" >&2
        return 2
    }
    if awk -v pgid="$pgid" '$1 == pgid {found = 1} END {exit !found}' \
        <<<"$process_groups"; then
        echo "recorded host process group $pgid is present but cannot be signaled" >&2
        return 2
    fi
    return 1
}

host_process_group_residue() {
    local pgid=$1

    echo "residue_host_process_group=$pgid" >&2
    sudo_cmd ps -eo pid=,ppid=,pgid=,sid=,stat=,args= |
        awk -v pgid="$pgid" \
            '$3 == pgid {print "residue_host_process=" $0}' >&2 || true
}

wait_for_host_process_group_exit() {
    local pgid=$1
    local group_state

    for _ in $(seq 1 50); do
        if host_process_group_state "$pgid"; then
            sleep 0.1
            continue
        fi
        group_state=$?
        if (( group_state == 1 )); then
            return 0
        fi
        return 1
    done
    return 1
}

stop_host_process_group() {
    local pid=$1
    local expected_start_time=$2
    local current_start_time
    local group_state

    [[ -n "$pid" ]] || return 0
    [[ "$pid" =~ ^[0-9]+$ && "$expected_start_time" =~ ^[0-9]+$ ]] || {
        echo "invalid monitor process identity: pid=$pid start=$expected_start_time" >&2
        return 1
    }
    if host_process_group_state "$pid"; then
        :
    else
        group_state=$?
        if (( group_state == 1 )); then
            return 0
        fi
        return 1
    fi
    if sudo_cmd kill -0 "$pid" >/dev/null 2>&1; then
        current_start_time=$(host_process_start_time "$pid") || {
            echo "refusing to signal monitor without a private process group: $pid" >&2
            return 1
        }
        [[ "$current_start_time" == "$expected_start_time" ]] || {
            echo "refusing to signal reused monitor pid: $pid" >&2
            return 1
        }
    else
        echo "recorded host process group $pid remains after its leader exited; refusing to signal it" >&2
        return 1
    fi
    if ! sudo_cmd kill -TERM -- "-$pid" >/dev/null 2>&1; then
        echo "failed to send TERM to host process group $pid" >&2
    fi
    if wait_for_host_process_group_exit "$pid"; then
        return 0
    fi
    echo "host process group $pid survived TERM; sending KILL" >&2
    host_process_group_residue "$pid"
    if ! sudo_cmd kill -KILL -- "-$pid" >/dev/null 2>&1; then
        echo "failed to send KILL to host process group $pid" >&2
    fi
    if wait_for_host_process_group_exit "$pid"; then
        return 0
    fi
    echo "host process group $pid survived KILL" >&2
    host_process_group_residue "$pid"
    return 1
}

stop_monitors() {
    local status=0

    if [[ -n "$dns_pid" ]]; then
        if stop_host_process_group "$dns_pid" "$dns_start_time"; then
            dns_pid=
            dns_start_time=
        else
            status=1
        fi
    fi
    if [[ -n "$grpc_pid" ]]; then
        if stop_host_process_group "$grpc_pid" "$grpc_start_time"; then
            grpc_pid=
            grpc_start_time=
        else
            status=1
        fi
    fi
    return "$status"
}

stop_client_jobs() {
    guest_cmd "$client_ip" \
        "stop_pid_file() {
            pid_file=\$1
            [ -s \"\$pid_file\" ] || return 0
            read -r pid expected_start_time <\"\$pid_file\"
            case \"\$pid:\$expected_start_time\" in
                *[!0-9:]*|:*|*:) echo \"invalid client process identity: \$pid_file\" >&2; return 1 ;;
            esac
            if ! kill -0 \"\$pid\" 2>/dev/null; then
                if kill -0 -- \"-\$pid\" 2>/dev/null; then
                    echo \"client leader \$pid exited while its process group remains\" >&2
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
                echo \"refusing to signal client process without its recorded group: \$pid\" >&2
                return 1
            fi
            kill -TERM -- \"-\$pid\" 2>/dev/null || true
            for _ in \$(seq 1 50); do
                kill -0 -- \"-\$pid\" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 -- \"-\$pid\" 2>/dev/null; then
                echo \"client process group \$pid did not stop gracefully\" >&2
                kill -KILL -- \"-\$pid\" 2>/dev/null || true
            fi
            if kill -0 -- \"-\$pid\" 2>/dev/null; then
                echo \"client process group \$pid survived KILL\" >&2
                return 1
            fi
            rm -f \"\$pid_file\"
        }
        status=0
        stop_pid_file '$client_dns_pid_file' || status=1
        stop_pid_file '$client_grpc_pid_file' || status=1
        exit \"\$status\""
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

cleanup() {
    local status=$?
    local lifecycle_failed=0
    trap - EXIT
    set +e
    stop_monitors || lifecycle_failed=1
    stop_client_jobs || lifecycle_failed=1
    stop_backend_services || lifecycle_failed=1
    if (( lifecycle_failed == 0 )); then
        guest_cmd "$client_ip" "rm -rf -- '$client_run_dir'" || lifecycle_failed=1
        guest_cmd "$backend_ip" \
            "sudo -n rm -rf -- '$pin_dir'; rm -rf -- '$backend_run_dir'" || lifecycle_failed=1
    else
        echo "preserving run directories and pin path after lifecycle validation failure" >&2
    fi
    if (( lifecycle_failed != 0 )); then
        [[ "$status" -ne 0 ]] || status=1
    fi
    {
        echo "lifecycle_failed=$lifecycle_failed"
        echo "host_dns_pid=${dns_pid:-none}"
        echo "host_grpc_pid=${grpc_pid:-none}"
        echo "client_run_dir=$client_run_dir"
        echo "backend_run_dir=$backend_run_dir"
        echo "backend_pin_dir=$pin_dir"
    } > "$out_dir/cleanup-audit.txt"
    rm -f "$sudo_askpass"
    printf 'cleanup_status=%s\ncleanup_lifecycle_failed=%s\n' \
        "$status" "$lifecycle_failed" > "$out_dir/cleanup-status.txt"
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
    dns_start_time=$(host_process_start_time "$dns_pid") || {
        echo "failed to record DNS monitor process group" >&2
        return 1
    }
    sleep 2
}

start_grpc_monitor() {
    local label=$1
    grpc_pid=$(sudo_cmd bash -c \
        "setsid '$grpc_monitor' --dev '$client_tap' --bpf-object '$grpc_bpf' --port 50052 --verbose-events >'$out_dir/$label.grpc-monitor.log' 2>&1 </dev/null & echo \$!")
    grpc_start_time=$(host_process_start_time "$grpc_pid") || {
        echo "failed to record gRPC monitor process group" >&2
        return 1
    }
    sleep 2
}

install_status() {
    local status=$1
    guest_cmd "$backend_ip" \
        "cat >'$backend_dynamic_policy' <<EOF
grpc-cache $method $payload $status 600
EOF
sudo -n '$backend_cachectl' --policy-file '$backend_dynamic_policy' --grpc-response-map '$pin_dir/grpc_response_cache' --replace"
}

for file in "$dns_harness" "$grpc_harness" "$grpc_cache" "$cachectl" \
    "$dns_monitor" "$dns_bpf" "$grpc_monitor" "$grpc_bpf"; do
    [[ -x "$file" || -r "$file" ]] || {
        echo "missing campaign input: $file" >&2
        exit 1
    }
done

guest_cmd "$client_ip" "mkdir -p '$client_run_dir'"
guest_cmd "$backend_ip" "mkdir -p '$backend_run_dir'"
copy_guest "$client_ip" "$dns_harness" "$client_dns_harness"
copy_guest "$client_ip" "$grpc_harness" "$client_grpc_harness"
copy_guest "$backend_ip" "$dns_harness" "$backend_dns_harness"
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
setsid nohup sudo -n '$backend_dns_harness' server 0.0.0.0 53 '$domain' '$answer_ip' 60 '$backend_dns_count' >'$backend_dns_log' 2>&1 </dev/null &
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
sleep 2
guest_cmd "$backend_ip" \
    "for pid_file in '$backend_dns_pid_file' '$backend_grpc_pid_file' '$backend_cache_pid_file'; do
    [ -s \"\$pid_file\" ] && ps -fp \"\$(awk '{print \$1}' \"\$pid_file\")\" || true
done
ss -lunp | grep ':53 ' || true
ss -ltnp | grep -E ':5005[12] ' || true
cat '$backend_grpc_log' '$backend_cache_log' 2>/dev/null || true" \
    > "$out_dir/service-state.txt"

printf 'round,baseline_qps,cache_qps,speedup,baseline_p99_us,cache_p99_us\n' \
    > "$out_dir/grpc-five-rounds.csv"
start_dns_monitor grpc-coexist
start_grpc_monitor grpc-coexist
verify_tc_order grpc-coexist
for round in $(seq 1 "$rounds"); do
    if ! baseline=$(guest_cmd "$client_ip" \
        "'$client_grpc_harness' client '$backend_ip' 50051 '$requests' '$warmup' '$payload'"); then
        echo "gRPC baseline failed in round $round" >&2
        cat "$out_dir/service-state.txt" >&2
        exit 1
    fi
    if ! cache=$(guest_cmd "$client_ip" \
        "'$client_grpc_harness' client '$backend_ip' 50052 '$requests' '$warmup' '$payload'"); then
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
setsid '$client_dns_harness' client '$backend_ip' 53 '$domain' '$answer_ip' '$requests' '$warmup' >'$client_run_dir/mixed-dns.out' </dev/null &
dns_job=\$!
record_process_group \"\$dns_job\" '$client_dns_pid_file' || exit 1
setsid '$client_grpc_harness' client '$backend_ip' 50052 '$requests' '$warmup' '$payload' >'$client_run_dir/mixed-grpc.out' </dev/null &
grpc_job=\$!
record_process_group \"\$grpc_job\" '$client_grpc_pid_file' || exit 1
wait \"\$dns_job\"
wait \"\$grpc_job\"
rm -f '$client_dns_pid_file' '$client_grpc_pid_file'
cat '$client_run_dir/mixed-dns.out'
cat '$client_run_dir/mixed-grpc.out'" > "$out_dir/mixed-$round.raw"
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
        "'$client_grpc_harness' client '$backend_ip' 50052 200 20 '$payload'")
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
