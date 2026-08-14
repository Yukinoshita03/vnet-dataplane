#!/usr/bin/env bash
set -Eeuo pipefail

# Paired OpenStack TAP-XDP path split benchmark.
#
# The existing realistic benchmark intentionally mixes cacheable and
# fail-open traffic.  This runner keeps the same VMs, backend, snapshots, and
# mode switching, but uses isolated corpora so the hit ceiling and miss-path
# overhead can be measured independently for A, AAAA and HTTPS.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_ssh="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-ssh.sh"
cluster_copy="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-copy.sh"
openstack_status="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/openstack-status.sh"
qga_exec_tool="${repo_root}/tools/openstack_qga_exec.sh"
qga_copy_tool="${repo_root}/tools/openstack_qga_copy_to.sh"

artifact_dir="${1:?usage: $0 ARTIFACT_DIR [target_qps] [duration_s] [repetitions]}"
target_qps="${2:-20000}"
duration="${3:-8}"
repetitions="${4:-3}"
warmup_duration="${WARMUP_DURATION:-2}"
run_id="$(basename "${artifact_dir}")"

client_instance="instance-0000000f"
backend_instance="instance-00000012"
client_tap="tap96696c4a-57"
backend_tap="tapaa5e3ccb-96"
backend_ip="192.168.110.13"
adapter_unit="linux-accel-openstack-tap-accel@96696c4a-5746-43ab-8137-241952309dac.service"
query_guest="/tmp/openstack-split-queries.txt"
correctness_guest="/tmp/openstack_dns_correctness.py"

[[ "${target_qps}" =~ ^[0-9]+$ && "${target_qps}" -gt 0 ]]
[[ "${duration}" =~ ^[0-9]+$ && "${duration}" -gt 0 ]]
[[ "${repetitions}" =~ ^[0-9]+$ && "${repetitions}" -gt 0 ]]
[[ "${warmup_duration}" =~ ^[0-9]+$ && "${warmup_duration}" -gt 0 ]]

mkdir -p "${artifact_dir}/cases" "${artifact_dir}/correctness" "${artifact_dir}/health" "${artifact_dir}/queries"

remote()
{
  local node="$1"
  shift
  "${cluster_ssh}" "${node}" -- "$@"
}

remote_payload()
{
  remote "$@" | sed '1d'
}

shell_quote()
{
  printf '%q' "$1"
}

client_guest()
{
  local command="$1"
  remote_payload node1 "/tmp/linux-accel-qga-exec.sh ${client_instance} $(shell_quote "${command}")"
}

backend_guest()
{
  local command="$1"
  remote_payload node2 "/tmp/linux-accel-qga-exec.sh ${backend_instance} $(shell_quote "${command}")"
}

backend_snapshot()
{
  backend_guest 'pid=$(systemctl show -p MainPID --value linux-accel-openstack-dns-backend.service); kill -USR1 "$pid"; sleep 0.2; cat /run/linux-accel-openstack-dns-backend.json' | tail -n 1
}

host_snapshot()
{
  local node="$1"
  local tap="$2"
  remote_payload "${node}" "sudo -n python3 /tmp/openstack_host_snapshot.py --tap ${tap} --interface enp3s0 --interface genev_sys_6081 --interface br-int" | tail -n 1
}

wait_for_xdp()
{
  remote node1 "for i in \$(seq 1 80); do state=\$(sudo -n bpftool net show dev ${client_tap} 2>/dev/null || true); if grep -q 'generic id' <<<\"\$state\" && grep -q 'clsact/egress' <<<\"\$state\"; then exit 0; fi; sleep 0.1; done; exit 1" >/dev/null
}

set_mode()
{
  local mode="$1"
  case "${mode}" in
    no_hook)
      remote node1 "sudo -n systemctl stop ${adapter_unit}; if sudo -n bpftool net show dev ${client_tap} 2>/dev/null | grep -Eq 'generic id|dns_client'; then exit 1; fi" >/dev/null
      ;;
    tap_xdp)
      remote node1 "sudo -n systemctl restart ${adapter_unit}" >/dev/null
      wait_for_xdp
      ;;
    *)
      echo "unknown mode: ${mode}" >&2
      return 2
      ;;
  esac
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${mode}" \
    "$(remote_payload node1 "sudo -n bpftool net show dev ${client_tap} 2>/dev/null | tr '\n' ' '" | tail -n 1)" \
    >>"${artifact_dir}/mode-transitions.tsv"
}

restore()
{
  set +e
  remote node1 "sudo -n systemctl start ${adapter_unit}" >/dev/null 2>&1
  wait_for_xdp >/dev/null 2>&1
}

on_exit()
{
  local status=$?
  trap - EXIT INT TERM
  restore
  exit "${status}"
}

on_interrupt()
{
  local status="$1"
  trap - EXIT INT TERM
  restore
  exit "${status}"
}

trap on_exit EXIT
trap 'on_interrupt 130' INT
trap 'on_interrupt 143' TERM

run_openstack_status()
{
  local output_path="$1"
  python3 - "${openstack_status}" "${output_path}" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys

command, output_path = sys.argv[1:]
with Path(output_path).open("w", encoding="utf-8") as output:
    process = subprocess.Popen(
        [command],
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        text=True,
    )
    try:
        status = process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        output.write("\nstatus_inventory_timeout=30s\n")
        status = 124
raise SystemExit(0 if status == 0 else status)
PY
}

generate_corpora()
{
  python3 - "${artifact_dir}/queries" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
domain = "openstack.example.test"
lines = 50000
spec = {
    "hot_cache": [f"hot-0001.{domain} A"],
    "aaaa": [f"v6-0001.{domain} AAAA"],
    "https": [f"https-0001.{domain} HTTPS"],
    "nxdomain": [f"nxd-0001.{domain} A"],
    "cname": [f"cname-0001.{domain} A"],
}
for name, values in spec.items():
    (root / f"{name}.txt").write_text("\n".join(values * lines) + "\n", encoding="ascii")

mixed = []
for index in range(lines):
    if index % 4 == 0:
        mixed.append(f"v6-0001.{domain} AAAA")
    elif index % 4 == 1:
        mixed.append(f"https-0001.{domain} HTTPS")
    elif index % 4 == 2:
        mixed.append(f"nxd-0001.{domain} A")
    else:
        mixed.append(f"cname-0001.{domain} A")
(root / "noncache_mixed.txt").write_text("\n".join(mixed) + "\n", encoding="ascii")

manifest = {
    "domain": domain,
    "lines_per_corpus": lines,
    "seed": "fixed-single-key",
    "corpora": {
        "hot_cache": "100% repeatable direct A; warmed before measurement",
        "aaaa": "100% direct AAAA; cache eligible in the narrow single-answer path",
        "https": "100% direct HTTPS/IN; cache eligible in the narrow single-answer path",
        "nxdomain": "100% NXDOMAIN; not cache eligible",
        "cname": "100% CNAME+A multi-answer; learner rejects",
        "noncache_mixed": "one-quarter each AAAA, HTTPS, NXDOMAIN, CNAME+A; only HTTPS is expected to hit the narrow cache",
    },
}
(root.parent / "corpus-manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="ascii"
)
PY
}

copy_query()
{
  local category="$1"
  local host_path="/tmp/openstack-split-${run_id}-${category}.txt"
  "${cluster_copy}" "${artifact_dir}/queries/${category}.txt" "${host_path}" node1 >/dev/null
  remote node1 "chmod 0755 /tmp/linux-accel-qga-copy-to.sh; /tmp/linux-accel-qga-copy-to.sh ${client_instance} ${host_path} ${query_guest} 0644" >/dev/null
}

perf_start()
{
  local node="$1"
  local remote_file="$2"
  local perf_duration="$3"
  remote_payload "${node}" "sudo -n perf stat -a -e cycles,instructions,context-switches,cpu-migrations -x, -o ${remote_file} -- sleep ${perf_duration} >/dev/null 2>&1 & echo \$!" | tail -n 1
}

perf_collect()
{
  local node="$1"
  local pid="$2"
  local remote_file="$3"
  local local_file="$4"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    printf 'perf_start_failed\n' >"${local_file}"
    return 0
  fi
  remote_payload "${node}" "while sudo -n kill -0 ${pid} 2>/dev/null; do sleep 0.1; done; sudo -n cat ${remote_file} 2>/dev/null || true" >"${local_file}"
}

run_correctness()
{
  local mode="$1"
  set_mode "${mode}"
  backend_snapshot >"${artifact_dir}/correctness/${mode}-backend-before.json"
  client_guest "python3 ${correctness_guest} --server ${backend_ip} --repeats 2" \
    >"${artifact_dir}/correctness/${mode}.json"
  backend_snapshot >"${artifact_dir}/correctness/${mode}-backend-after.json"
}

run_case()
{
  local category="$1"
  local mode="$2"
  local repetition="$3"
  local directory="${artifact_dir}/cases/${category}-r${repetition}-${mode}"
  local perf_duration=$((duration + warmup_duration + 3))
  local node1_perf_remote="/tmp/openstack-${run_id}-${category}-r${repetition}-${mode}-node1.perf"
  local node2_perf_remote="/tmp/openstack-${run_id}-${category}-r${repetition}-${mode}-node2.perf"
  local node1_perf_pid
  local node2_perf_pid
  local dnsperf_rc

  echo "running category=${category} mode=${mode} repetition=${repetition} target=${target_qps} duration=${duration}s"
  mkdir -p "${directory}"
  jq -n \
    --arg category "${category}" \
    --arg phase "path_split" \
    --arg mode "${mode}" \
    --argjson repetition "${repetition}" \
    --argjson target_qps "${target_qps}" \
    --argjson duration "${duration}" \
    --arg client_tap "${client_tap}" \
    --arg backend_tap "${backend_tap}" \
    '{category:$category,phase:$phase,mode:$mode,repetition:$repetition,target_qps:$target_qps,duration:$duration,client_tap:$client_tap,backend_tap:$backend_tap}' \
    >"${directory}/metadata.json"

  set_mode "${mode}"
  client_guest "LC_ALL=C dnsperf -s ${backend_ip} -p 53 -d ${query_guest} -l ${warmup_duration} -Q 5000 -q 10000 -T 2 -c 8 -t 1 >/dev/null 2>&1"
  backend_snapshot >"${directory}/backend-before.json"
  host_snapshot node1 "${client_tap}" >"${directory}/node1-before.json"
  host_snapshot node2 "${backend_tap}" >"${directory}/node2-before.json"
  node1_perf_pid="$(perf_start node1 "${node1_perf_remote}" "${perf_duration}")"
  node2_perf_pid="$(perf_start node2 "${node2_perf_remote}" "${perf_duration}")"

  set +e
  client_guest "LC_ALL=C /usr/bin/time -v dnsperf -s ${backend_ip} -p 53 -d ${query_guest} -l ${duration} -Q ${target_qps} -q 20000 -T 2 -c 8 -t 1 -S 1 -O latency-histogram 2>&1" \
    >"${directory}/dnsperf.log" 2>&1
  dnsperf_rc=$?
  set -e
  printf '%s\n' "${dnsperf_rc}" >"${directory}/dnsperf.exit"

  perf_collect node1 "${node1_perf_pid}" "${node1_perf_remote}" "${directory}/node1-perf.csv"
  perf_collect node2 "${node2_perf_pid}" "${node2_perf_remote}" "${directory}/node2-perf.csv"
  backend_snapshot >"${directory}/backend-after.json"
  host_snapshot node1 "${client_tap}" >"${directory}/node1-after.json"
  host_snapshot node2 "${backend_tap}" >"${directory}/node2-after.json"
  if ! python3 "${repo_root}/tools/parse_dnsperf.py" "${directory}/dnsperf.log" \
    >"${directory}/dnsperf.json"; then
    printf '{"parse_error":true}\n' >"${directory}/dnsperf.json"
  fi
  if [ "${dnsperf_rc}" -ne 0 ]; then
    echo "dnsperf failed in ${category}-r${repetition}-${mode}: rc=${dnsperf_rc}" >&2
  fi
}

# The bundled inventory section can exceed the timeout while the API checks
# remain healthy; retain the output but gate only on the API lines below.
run_openstack_status "${artifact_dir}/health/openstack-before.txt" || true
grep -Eq '^Horizon[[:space:]]+200$' "${artifact_dir}/health/openstack-before.txt"
grep -Eq '^Keystone[[:space:]]+200$' "${artifact_dir}/health/openstack-before.txt"
grep -Eq '^Neutron[[:space:]]+200$' "${artifact_dir}/health/openstack-before.txt"
remote all 'for unit in kubelet containerd kubernetes-haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
  >"${artifact_dir}/health/kubernetes-before.txt"
if grep -q '=active$' "${artifact_dir}/health/kubernetes-before.txt"; then
  echo "Kubernetes must remain stopped during this benchmark" >&2
  exit 1
fi

generate_corpora
"${cluster_copy}" "${qga_copy_tool}" /tmp/linux-accel-qga-copy-to.sh node1 >/dev/null
"${cluster_copy}" "${qga_exec_tool}" /tmp/linux-accel-qga-exec.sh node1 >/dev/null
"${cluster_copy}" "${qga_copy_tool}" /tmp/linux-accel-qga-copy-to.sh node2 >/dev/null
"${cluster_copy}" "${qga_exec_tool}" /tmp/linux-accel-qga-exec.sh node2 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_dns_correctness.py" /tmp/openstack_dns_correctness.py node1 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_host_snapshot.py" /tmp/openstack_host_snapshot.py node1 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_host_snapshot.py" /tmp/openstack_host_snapshot.py node2 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_dns_backend.py" /tmp/openstack_dns_backend.py node2 >/dev/null
remote node1 "chmod 0755 /tmp/linux-accel-qga-copy-to.sh"
remote node2 "chmod 0755 /tmp/linux-accel-qga-copy-to.sh"
remote node2 "chmod 0755 /tmp/linux-accel-qga-exec.sh"
remote node2 "chmod 0755 /tmp/openstack_host_snapshot.py"
remote node1 "chmod 0755 /tmp/openstack_host_snapshot.py"
remote node1 "chmod 0755 /tmp/openstack_dns_correctness.py"
remote node2 "chmod 0755 /tmp/openstack_dns_backend.py"

remote node2 "/tmp/linux-accel-qga-copy-to.sh ${backend_instance} /tmp/openstack_dns_backend.py /usr/local/libexec/linux-accel/openstack_dns_backend.py.bench-${run_id} 0755" >/dev/null
backend_guest "candidate=/usr/local/libexec/linux-accel/openstack_dns_backend.py.bench-${run_id}; current=/usr/local/libexec/linux-accel/openstack_dns_backend.py; if [ ! -f \"\$current\" ] || ! cmp -s \"\$candidate\" \"\$current\"; then if [ -f \"\$current\" ]; then cp -a \"\$current\" \"\$current.pre-split-${run_id}\"; fi; mv \"\$candidate\" \"\$current\"; systemctl restart linux-accel-openstack-dns-backend.service; fi; systemctl is-active linux-accel-openstack-dns-backend.service"
client_guest "command -v dnsperf; command -v /usr/bin/time; ping -c 2 -W 1 ${backend_ip}"
backend_guest 'systemctl is-active linux-accel-openstack-dns-backend.service; python3 -m py_compile /usr/local/libexec/linux-accel/openstack_dns_backend.py'

{
  echo "run_id=${run_id}"
  echo "target_qps=${target_qps}"
  echo "duration=${duration}"
  echo "repetitions=${repetitions}"
  echo "warmup_duration=${warmup_duration}"
  echo "client_vm=linux-accel-client node1 ${client_instance} ${client_tap}"
  echo "backend_vm=linux-accel-backend node2 ${backend_instance} ${backend_tap} ${backend_ip}"
  echo "corpus_sha256=$(shasum -a 256 "${artifact_dir}"/queries/*.txt)"
} >"${artifact_dir}/metadata.txt"

run_correctness no_hook
run_correctness tap_xdp

for category in hot_cache aaaa https nxdomain cname noncache_mixed; do
  copy_query "${category}"
  for repetition in $(seq 1 "${repetitions}"); do
    if (( repetition % 2 == 1 )); then
      modes=(no_hook tap_xdp)
    else
      modes=(tap_xdp no_hook)
    fi
    for mode in "${modes[@]}"; do
      run_case "${category}" "${mode}" "${repetition}"
    done
  done
done

set_mode tap_xdp
run_openstack_status "${artifact_dir}/health/openstack-after.txt" || true
remote all 'for unit in kubelet containerd kubernetes-haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
  >"${artifact_dir}/health/kubernetes-after.txt"
remote node1 "systemctl is-active ${adapter_unit}; sudo -n bpftool net show dev ${client_tap}" \
  >"${artifact_dir}/health/adapter-after.txt"
backend_guest 'systemctl is-active linux-accel-openstack-dns-backend.service' \
  >"${artifact_dir}/health/backend-after.txt"

python3 "${repo_root}/tools/analyze_openstack_dns_path_split.py" "${artifact_dir}" \
  >"${artifact_dir}/analysis-output.txt"
cat "${artifact_dir}/summary.md"
