#!/usr/bin/env bash
set -Eeuo pipefail

# Reproducible physical-path comparison for the persistent UDP client.
# The cluster helper is used deliberately: the school nodes are offline and
# the Mac is the staging/orchestration host.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_ssh="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-ssh.sh"
cluster_copy="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-copy.sh"
openstack_status="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/openstack-status.sh"
artifact_dir="${1:?usage: $0 ARTIFACT_DIR}"
mkdir -p "$artifact_dir"

remote_release="${REMOTE_RELEASE:-/opt/competitor-bench/releases/linux-accel-all-comparisons-20260814-v2/linux-accel}"
expected_driver="${EXPECTED_DRIVER:-r8169_xdp}"
preflight_only="${PREFLIGHT_ONLY:-0}"

client="/tmp/physical_xdp_burst_client"
queries_remote="/tmp/physical-realistic-queries.txt"
target_ip="10.115.24.245"
peer_ip="10.115.24.114"
irq="148"
irq_cpu="1"
server_cpu="2"
backend_cpu="3"
client_cpu_base="2"
threads="${THREADS:-4}"
batch="${BATCH:-32}"
timeout_us="${TIMEOUT_US:-50000}"
rates_csv="${RATES:-100000,500000,1000000}"
duration_sec="${DURATION:-3}"
repetitions="${REPETITIONS:-1}"
IFS=',' read -r -a rates <<< "$rates_csv"

remote()
{
    local node="$1"
    shift
    "$cluster_ssh" "$node" -- "$@"
}

remote_last_line()
{
    remote "$@" | tail -n 1
}

path_pids()
{
    remote node1 'pgrep -f "[d]ns_monitor --dev enp3s0|[o]penstack_dns_backend.py" || true' |
        sed '1d' |
        awk 'NF {print $NF}'
}

stop_path()
{
    remote node1 '
        for pid in $(pgrep -f "[d]ns_monitor --dev enp3s0" || true); do
            sudo -n kill "$pid" 2>/dev/null || true
        done
        for pid in $(pgrep -f "[o]penstack_dns_backend.py" || true); do
            sudo -n kill "$pid" 2>/dev/null || true
        done
    ' >/dev/null
    sleep 4
}

wait_carrier()
{
    local n=0
    while (( n < 50 )); do
        if remote node1 'test "$(cat /sys/class/net/enp3s0/carrier)" = 1' >/dev/null 2>&1 &&
           remote node2 "ping -c 1 -W 1 $target_ip" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
        n=$((n + 1))
    done
    echo "carrier/peer did not recover" >&2
    return 1
}

pin_server()
{
    local pid="$1"
    remote node1 "sudo -n taskset -cp $server_cpu $pid" >/dev/null
}

start_mode()
{
    local mode="$1"
    local pid
    local backend_pid
    local start_command
    stop_path

    start_command="sudo -n bash -c 'nohup python3 /tmp/openstack_dns_backend.py --bind $target_ip --port 53 --domain example.test --answer 10.0.0.123 --ttl 300 --count-file /tmp/physical-$mode-count.json >/tmp/physical-$mode-backend.log 2>&1 </dev/null & echo \$!'"
    timeout 5s "$cluster_ssh" node1 -- "$start_command" >/dev/null 2>&1 || true
    backend_pid="$(remote_last_line node1 'pgrep -n -f "[o]penstack_dns_backend.py" || true')"
    if [[ ! "$backend_pid" =~ ^[0-9]+$ ]]; then
        echo "could not find userspace backend for $mode" >&2
        return 1
    fi
    if [[ "$mode" == "userspace" ]]; then
        remote node1 "sudo -n taskset -cp $server_cpu $backend_pid" >/dev/null
    else
        remote node1 "sudo -n taskset -cp $backend_cpu $backend_pid" >/dev/null
    fi

    if [[ "$mode" == "userspace" ]]; then
        pid="$backend_pid"
    else
        start_command="sudo -n bash -c 'cd $remote_release && nohup ./build/dns_monitor --dev enp3s0 --hook xdp --role server --xdp-mode $mode --cache-domain example.test --cache-ip 10.0.0.123 --cache-ttl 300 >/tmp/physical-$mode-monitor.log 2>&1 </dev/null & echo \$!'"
        timeout 5s "$cluster_ssh" node1 -- "$start_command" >/dev/null 2>&1 || true
        pid="$(remote_last_line node1 'pgrep -n -f "[d]ns_monitor --dev enp3s0" || true')"
    fi
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "could not find $mode datapath process" >&2
        return 1
    fi
    pin_server "$pid"
    wait_carrier
    printf '%s\tpid=%s\tstate=%s\n' "$mode" "$pid" \
        "$(remote node1 'ip -details link show dev enp3s0 | sed -n "s/.*prog\/xdp id \([0-9]*\).*/native:\1/p; s/.*xdpgeneric id \([0-9]*\).*/generic:\1/p" | head -1' | tail -n 1)" \
        >>"$artifact_dir/mode-transitions.tsv"
    echo "$mode pid=$pid ready"
}

snapshot()
{
    local label="$1"
    local row
    row="$(remote node1 'python3 /tmp/physical_xdp_snapshot.py')"
    printf '%s\t%s\n' "$label" "$row" >>"$artifact_dir/counters.tsv"
}

health()
{
    local label="$1"
    {
        echo "[$label] node1-carrier"
        remote node1 'cat /sys/class/net/enp3s0/carrier; ip -details link show dev enp3s0 | sed -n "1,5p"'
        echo "[$label] node2-peer"
        remote node2 "ping -c 2 -W 1 $target_ip"
        echo "[$label] openstack"
        "$openstack_status" || true
        echo "[$label] kube-services-must-remain-off"
        remote all 'systemctl is-active kubelet containerd kubernetes-haproxy 2>/dev/null || true'
    } >"$artifact_dir/health-$label.txt" 2>&1
    if ! grep -Eq '^Horizon[[:space:]]+200$' "$artifact_dir/health-$label.txt" ||
       ! grep -Eq '^Keystone[[:space:]]+200$' "$artifact_dir/health-$label.txt" ||
       ! grep -Eq '^Neutron[[:space:]]+200$' "$artifact_dir/health-$label.txt"; then
        echo "OpenStack API health check failed after $label" >&2
        return 1
    fi
}

run_rate()
{
    local mode="$1"
    local rate="$2"
    local duration="$3"
    local repetition="$4"
    local case_name="${mode}-r${repetition}-${rate}"
    local perf_file="/tmp/physical-xdp-${case_name}-node1.perf"
    local perf_pid
    local client_output
    local node1_perf

    echo "running $case_name"
    snapshot "${case_name}-before"
    perf_pid="$(remote_last_line node1 "sudo -n perf stat -a -e cycles,instructions,context-switches,cpu-migrations -x, -o $perf_file -- sleep $((duration + 2)) >/dev/null 2>&1 & echo \$!")"
    sleep 0.5
    client_output="$(remote node2 "sudo -n perf stat -x, -e cycles,instructions,context-switches,cpu-migrations -- $client --target $target_ip --rate $rate --duration $duration --threads $threads --batch $batch --timeout-us $timeout_us --cpu-base $client_cpu_base --queries $queries_remote 2>&1" || true)"
    printf '%s\n' "$client_output" >"$artifact_dir/client-$case_name.txt"
    node1_perf="$(remote node1 "while sudo -n kill -0 $perf_pid 2>/dev/null; do sleep 0.1; done; cat $perf_file 2>/dev/null || true")"
    printf '%s\n' "$node1_perf" >"$artifact_dir/node1-perf-$case_name.txt"
    snapshot "${case_name}-after"
    health "$case_name"
}

orig_irq1="$(remote_last_line node1 "cat /proc/irq/$irq/smp_affinity_list")"
orig_irq2="$(remote_last_line node2 "cat /proc/irq/$irq/smp_affinity_list")"
irqbalance1="$(remote_last_line node1 'systemctl is-active irqbalance || true')"
irqbalance2="$(remote_last_line node2 'systemctl is-active irqbalance || true')"

restore()
{
    set +e
    stop_path >/dev/null 2>&1 || true
    remote node1 "echo $irq_cpu | sudo -n tee /proc/irq/$irq/smp_affinity_list >/dev/null" >/dev/null 2>&1 || true
    remote node2 "echo $irq_cpu | sudo -n tee /proc/irq/$irq/smp_affinity_list >/dev/null" >/dev/null 2>&1 || true
    remote node1 "echo $orig_irq1 | sudo -n tee /proc/irq/$irq/smp_affinity_list >/dev/null" >/dev/null 2>&1 || true
    remote node2 "echo $orig_irq2 | sudo -n tee /proc/irq/$irq/smp_affinity_list >/dev/null" >/dev/null 2>&1 || true
    if [[ "$irqbalance1" == "active" ]]; then
        remote node1 'sudo -n systemctl start irqbalance' >/dev/null 2>&1 || true
    fi
    if [[ "$irqbalance2" == "active" ]]; then
        remote node2 'sudo -n systemctl start irqbalance' >/dev/null 2>&1 || true
    fi
    # The preflight below requires a hook-free interface, so restore that
    # exact state rather than leaving a benchmark-owned native hook behind.
    wait_carrier >/dev/null 2>&1 || true
}

if remote all \
    'for unit in kubelet containerd kubernetes-haproxy; do test "$(systemctl is-active "$unit" 2>/dev/null || true)" != active || exit 1; done' \
    >/dev/null 2>&1; then
    :
else
    echo "Kubernetes must remain stopped during the physical XDP benchmark" >&2
    exit 1
fi
if remote node1 'sudo -n bpftool net show dev enp3s0 2>/dev/null | grep -Eq "(generic|native|offload) id"' \
    >/dev/null 2>&1; then
    echo "enp3s0 already has an XDP program; refusing to replace an unknown owner" >&2
    exit 1
fi
if [[ -n "$(path_pids)" ]]; then
    echo "a physical DNS benchmark process is already running" >&2
    exit 1
fi
remote node1 "test -x $remote_release/build/dns_monitor"
actual_driver="$(remote_last_line node1 \
    'ethtool -i enp3s0 | sed -n "s/^driver: //p"')"
if [[ "$actual_driver" != "$expected_driver" ]]; then
    echo "enp3s0 driver mismatch: expected $expected_driver, found $actual_driver" >&2
    echo "load and bind the reviewed r8169_xdp module from the local/OOB console before running native XDP" >&2
    exit 1
fi
if [[ "$preflight_only" == 1 ]]; then
    echo "physical XDP preflight passed: driver=$actual_driver release=$remote_release"
    exit 0
fi
trap restore EXIT INT TERM

"$cluster_copy" "$repo_root/bench/physical_xdp_snapshot.py" \
    /tmp/physical_xdp_snapshot.py node1 >/dev/null
"$cluster_copy" "$repo_root/bench/openstack_dns_backend.py" \
    /tmp/openstack_dns_backend.py node1 >/dev/null
"$cluster_copy" "$repo_root/bench/physical_xdp_burst_client.c" \
    /tmp/physical_xdp_burst_client.c node2 >/dev/null

queries_local="$artifact_dir/queries.txt"
manifest_local="$artifact_dir/corpus-manifest.json"
python3 "$repo_root/tools/generate_openstack_dns_corpus.py" \
    --output "$queries_local.bootstrap" --manifest "$manifest_local" \
    --domain example.test --lines 50000 --seed 20260806
python3 - "$queries_local.bootstrap" "$queries_local" <<'PY'
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
rows = []
for line in source.read_text(encoding="ascii").splitlines():
    name, qtype = line.split()
    if name.startswith("hot-") and qtype == "A":
        name = "example.test"
    rows.append(f"{name} {qtype}")
destination.write_text("\n".join(rows) + "\n", encoding="ascii")
source.unlink()
PY
"$cluster_copy" "$queries_local" "$queries_remote" node2 >/dev/null
remote node2 "gcc -O2 -g -Wall -Wextra -pthread /tmp/physical_xdp_burst_client.c -o $client"

{
    echo "artifact=$(cd "$artifact_dir" && pwd)"
    echo "target=$target_ip peer=$peer_ip irq=$irq irq_cpu=$irq_cpu server_cpu=$server_cpu backend_cpu=$backend_cpu"
    echo "client=$client threads=$threads batch=$batch timeout_us=$timeout_us queries=$queries_remote"
    echo "orig_irq_node1=$orig_irq1 orig_irq_node2=$orig_irq2 irqbalance_node1=$irqbalance1 irqbalance_node2=$irqbalance2"
    echo "rates=$rates_csv duration_sec=$duration_sec repetitions=$repetitions"
} >"$artifact_dir/metadata.txt"

remote node1 'sudo -n systemctl stop irqbalance'
remote node2 'sudo -n systemctl stop irqbalance'
remote node1 "echo $irq_cpu | sudo -n tee /proc/irq/$irq/smp_affinity_list >/dev/null"
remote node2 "echo $irq_cpu | sudo -n tee /proc/irq/$irq/smp_affinity_list >/dev/null"

for mode in userspace generic native; do
    start_mode "$mode"
    for repetition in $(seq 1 "$repetitions"); do
        for rate in "${rates[@]}"; do
            if [[ ! "$rate" =~ ^[0-9]+$ ]] || (( rate < 1 )); then
                echo "invalid RATES entry: $rate" >&2
                exit 2
            fi
            run_rate "$mode" "$rate" "$duration_sec" "$repetition"
        done
    done
done

echo "physical XDP burst experiment completed: $artifact_dir"
