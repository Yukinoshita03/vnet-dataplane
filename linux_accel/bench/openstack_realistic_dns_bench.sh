#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_ssh="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-ssh.sh"
cluster_copy="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-copy.sh"
openstack_status="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/openstack-status.sh"
qga_exec_tool="${repo_root}/tools/openstack_qga_exec.sh"
qga_copy_tool="${repo_root}/tools/openstack_qga_copy_to.sh"
artifact_dir="${1:?usage: $0 ARTIFACT_DIR [quick|full]}"
profile="${2:-quick}"

client_instance="instance-0000000f"
backend_instance="instance-00000012"
client_tap="tap96696c4a-57"
backend_tap="tapaa5e3ccb-96"
backend_ip="192.168.110.13"
adapter_unit="linux-accel-openstack-tap-accel@96696c4a-5746-43ab-8137-241952309dac.service"
query_guest="/tmp/openstack-realistic-queries.txt"
correctness_guest="/tmp/openstack_dns_correctness.py"
run_id="$(basename "${artifact_dir}")"

case "${profile}" in
  quick)
    rates=(5000 10000 20000 40000 80000 120000)
    scan_duration=5
    steady_duration=8
    steady_repetitions=3
    warmup_duration=2
    resperf_ramp=15
    ;;
  full)
    rates=(5000 10000 20000 40000 60000 80000 100000 120000 160000)
    scan_duration=10
    steady_duration=30
    steady_repetitions=5
    warmup_duration=5
    resperf_ramp=30
    ;;
  *)
    echo "profile must be quick or full" >&2
    exit 2
    ;;
esac

mkdir -p "${artifact_dir}/cases" "${artifact_dir}/correctness" \
  "${artifact_dir}/resperf" "${artifact_dir}/health"

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
  remote node1 "for i in \$(seq 1 50); do state=\$(sudo -n bpftool net show dev ${client_tap} 2>/dev/null || true); if grep -q 'generic id' <<<\"\$state\" && grep -q 'clsact/egress' <<<\"\$state\"; then exit 0; fi; sleep 0.1; done; exit 1" >/dev/null
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
        status = process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        output.write("\nstatus_inventory_timeout=20s\n")
        status = 124
raise SystemExit(status)
PY
}

warmup()
{
  local target_qps="$1"
  local warm_qps=5000
  if [ "${target_qps}" -lt "${warm_qps}" ]; then
    warm_qps="${target_qps}"
  fi
  client_guest "LC_ALL=C dnsperf -s ${backend_ip} -p 53 -d ${query_guest} -l ${warmup_duration} -Q ${warm_qps} -q 10000 -T 2 -c 8 -t 1 >/dev/null 2>&1"
}

perf_start()
{
  local node="$1"
  local remote_file="$2"
  local duration="$3"
  remote_payload "${node}" "sudo -n perf stat -a -e cycles,instructions,context-switches,cpu-migrations -x, -o ${remote_file} -- sleep ${duration} >/dev/null 2>&1 & echo \$!" | tail -n 1
}

perf_collect()
{
  local node="$1"
  local pid="$2"
  local remote_file="$3"
  local local_file="$4"
  if [[ ! ${pid} =~ ^[0-9]+$ ]]; then
    printf 'perf_start_failed\n' >"${local_file}"
    return 0
  fi
  remote_payload "${node}" "while sudo -n kill -0 ${pid} 2>/dev/null; do sleep 0.1; done; sudo -n cat ${remote_file} 2>/dev/null || true" >"${local_file}"
}

run_correctness()
{
  local mode="$1"
  local directory="${artifact_dir}/correctness/${mode}-evidence"
  mkdir -p "${directory}"
  set_mode "${mode}"
  backend_snapshot >"${directory}/backend-before.json"
  host_snapshot node1 "${client_tap}" >"${directory}/node1-before.json"
  client_guest "python3 ${correctness_guest} --server ${backend_ip} --repeats 2" \
    >"${artifact_dir}/correctness/${mode}.json"
  backend_snapshot >"${directory}/backend-after.json"
  host_snapshot node1 "${client_tap}" >"${directory}/node1-after.json"
  python3 - "${mode}" "${artifact_dir}/correctness/${mode}.json" \
    "${directory}/backend-before.json" "${directory}/backend-after.json" \
    "${directory}/node1-before.json" "${directory}/node1-after.json" <<'PY'
import json
import sys

mode, result_path, backend_before_path, backend_after_path, host_before_path, host_after_path = sys.argv[1:]
load = lambda path: json.load(open(path, encoding="utf-8"))
result = load(result_path)
backend_before, backend_after = load(backend_before_path), load(backend_after_path)
host_before, host_after = load(host_before_path), load(host_after_path)
if not result.get("passed"):
    raise SystemExit("DNS correctness failed")
backend_delta = backend_after["requests"] - backend_before["requests"]
if mode == "no_hook" and backend_delta != 18:
    raise SystemExit(f"baseline correctness expected 18 backend requests, saw {backend_delta}")
if mode == "tap_xdp":
    before = host_before.get("bpf", {})
    after = host_after.get("bpf", {})
    tx_delta = after.get("cache_tx", 0) - before.get("cache_tx", 0)
    if tx_delta < 4 or backend_delta >= 18:
        raise SystemExit(f"XDP correctness did not prove offload: tx={tx_delta} backend={backend_delta}")
print(f"correctness mode={mode} backend_delta={backend_delta} passed=true")
PY
}

run_resperf()
{
  local mode="$1"
  set_mode "${mode}"
  warmup 5000
  client_guest "set +e; LC_ALL=C resperf -s ${backend_ip} -p 53 -d ${query_guest} -r ${resperf_ramp} -m 120000 -c 0 -L 1 -C 4 -q 65536 -t 1 -R -F 0 -P /tmp/openstack-${mode}-resperf.plot -v; rc=\$?; echo RESPERF_EXIT=\$rc; echo RESPERF_PLOT; sed -n '1,240p' /tmp/openstack-${mode}-resperf.plot; exit 0" \
    >"${artifact_dir}/resperf/${mode}.log"
}

run_case()
{
  local case_name="$1"
  local phase="$2"
  local mode="$3"
  local target_qps="$4"
  local duration="$5"
  local repetition="$6"
  local directory="${artifact_dir}/cases/${case_name}"
  local perf_duration=$((duration + 2))
  local node1_perf_remote="/tmp/openstack-${run_id}-${case_name}-node1.perf"
  local node2_perf_remote="/tmp/openstack-${run_id}-${case_name}-node2.perf"
  local node1_perf_pid
  local node2_perf_pid
  local dnsperf_rc

  echo "running case=${case_name} mode=${mode} target=${target_qps} duration=${duration}s"
  mkdir -p "${directory}"
  jq -n \
    --arg case "${case_name}" \
    --arg phase "${phase}" \
    --arg mode "${mode}" \
    --argjson repetition "${repetition}" \
    --argjson target_qps "${target_qps}" \
    --argjson duration "${duration}" \
    --arg client_tap "${client_tap}" \
    --arg backend_tap "${backend_tap}" \
    '{case:$case,phase:$phase,mode:$mode,repetition:$repetition,target_qps:$target_qps,duration:$duration,client_tap:$client_tap,backend_tap:$backend_tap}' \
    >"${directory}/metadata.json"

  set_mode "${mode}"
  warmup "${target_qps}"
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
  python3 "${repo_root}/tools/parse_dnsperf.py" "${directory}/dnsperf.log" \
    >"${directory}/dnsperf.json"
  if [ "${dnsperf_rc}" -ne 0 ]; then
    echo "dnsperf failed in ${case_name}: rc=${dnsperf_rc}" >&2
    return "${dnsperf_rc}"
  fi
}

select_rates()
{
  python3 - "${artifact_dir}" "${rates[@]}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
rates = [int(value) for value in sys.argv[2:]]
passing = []
for path in root.glob("cases/scan-*-no_hook/dnsperf.json"):
    data = json.load(path.open(encoding="utf-8"))
    metadata = json.load((path.parent / "metadata.json").open(encoding="utf-8"))
    target = int(metadata["target_qps"])
    if (
        data["sent_qps"] >= target * 0.99
        and data["completion_percent"] >= 99.9
        and data.get("p99_latency_us", 1e99) <= 10000
    ):
        passing.append(target)
knee = max(passing, default=rates[0])
steady_candidates = [rate for rate in rates if rate <= knee * 0.6]
steady = max(steady_candidates, default=rates[0])
higher = [rate for rate in rates if rate > knee]
burst = min(higher, default=max(rates))
print(steady, burst, knee)
PY
}

query_local="${artifact_dir}/queries.txt"
manifest_local="${artifact_dir}/corpus-manifest.json"
if [ ! -s "${query_local}" ]; then
  python3 "${repo_root}/tools/generate_openstack_dns_corpus.py" \
    --output "${query_local}" --manifest "${manifest_local}" \
    --lines 50000 --seed 20260805
fi

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

"${cluster_copy}" "${qga_copy_tool}" /tmp/linux-accel-qga-copy-to.sh node1 >/dev/null
"${cluster_copy}" "${qga_copy_tool}" /tmp/linux-accel-qga-copy-to.sh node2 >/dev/null
"${cluster_copy}" "${qga_exec_tool}" /tmp/linux-accel-qga-exec.sh node1 >/dev/null
"${cluster_copy}" "${qga_exec_tool}" /tmp/linux-accel-qga-exec.sh node2 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_dns_correctness.py" \
  /tmp/openstack_dns_correctness.py node1 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_host_snapshot.py" \
  /tmp/openstack_host_snapshot.py node1 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_host_snapshot.py" \
  /tmp/openstack_host_snapshot.py node2 >/dev/null
"${cluster_copy}" "${query_local}" /tmp/openstack-realistic-queries.txt node1 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_dns_backend.py" \
  /tmp/openstack_dns_backend.py node2 >/dev/null
remote node1 "chmod 0755 /tmp/linux-accel-qga-copy-to.sh; /tmp/linux-accel-qga-copy-to.sh ${client_instance} /tmp/openstack_dns_correctness.py ${correctness_guest} 0755; /tmp/linux-accel-qga-copy-to.sh ${client_instance} /tmp/openstack-realistic-queries.txt ${query_guest} 0644" >/dev/null
remote node2 "chmod 0755 /tmp/linux-accel-qga-copy-to.sh; /tmp/linux-accel-qga-copy-to.sh ${backend_instance} /tmp/openstack_dns_backend.py /usr/local/libexec/linux-accel/openstack_dns_backend.py.bench-${run_id} 0755" >/dev/null

backend_guest "candidate=/usr/local/libexec/linux-accel/openstack_dns_backend.py.bench-${run_id}; current=/usr/local/libexec/linux-accel/openstack_dns_backend.py; if [ ! -f \"\$current\" ] || ! cmp -s \"\$candidate\" \"\$current\"; then if [ -f \"\$current\" ]; then cp -a \"\$current\" \"\$current.pre-bench-${run_id}\"; fi; mv \"\$candidate\" \"\$current\"; systemctl restart linux-accel-openstack-dns-backend.service; fi; systemctl is-active linux-accel-openstack-dns-backend.service"

client_guest "command -v dnsperf; command -v resperf; command -v /usr/bin/time; test \$(wc -l < ${query_guest}) -eq 50000; ping -c 2 -W 1 ${backend_ip}"
backend_guest 'systemctl is-active linux-accel-openstack-dns-backend.service; python3 -m py_compile /usr/local/libexec/linux-accel/openstack_dns_backend.py'

{
  echo "run_id=${run_id}"
  echo "profile=${profile}"
  echo "rates=${rates[*]}"
  echo "scan_duration=${scan_duration}"
  echo "steady_duration=${steady_duration}"
  echo "steady_repetitions=${steady_repetitions}"
  echo "warmup_duration=${warmup_duration}"
  echo "client_vm=linux-accel-client node1 ${client_instance} ${client_tap}"
  echo "backend_vm=linux-accel-backend node2 ${backend_instance} ${backend_tap} ${backend_ip}"
  echo "dnsperf_package=$(client_guest "dpkg -s dnsperf | sed -n 's/^Version: /dnsperf /p'" | tail -n 1)"
  echo "corpus_sha256=$(shasum -a 256 "${query_local}" | awk '{print $1}')"
} >"${artifact_dir}/metadata.txt"

run_correctness no_hook
run_correctness tap_xdp
run_resperf no_hook
run_resperf tap_xdp

rate_index=0
for rate in "${rates[@]}"; do
  if (( rate_index % 2 == 0 )); then
    modes=(no_hook tap_xdp)
  else
    modes=(tap_xdp no_hook)
  fi
  for mode in "${modes[@]}"; do
    run_case "scan-${rate}-${mode}" scan "${mode}" "${rate}" "${scan_duration}" 1
  done
  rate_index=$((rate_index + 1))
done

read -r steady_rate burst_rate baseline_knee < <(select_rates)
printf 'steady_rate=%s\nburst_rate=%s\nbaseline_knee=%s\n' \
  "${steady_rate}" "${burst_rate}" "${baseline_knee}" \
  >"${artifact_dir}/selected-rates.txt"

for repetition in $(seq 1 "${steady_repetitions}"); do
  if (( repetition % 2 == 1 )); then
    modes=(no_hook tap_xdp)
  else
    modes=(tap_xdp no_hook)
  fi
  for mode in "${modes[@]}"; do
    run_case "steady-r${repetition}-${mode}" steady "${mode}" \
      "${steady_rate}" "${steady_duration}" "${repetition}"
  done
done

run_case "spike-${burst_rate}-tap_xdp" spike tap_xdp "${burst_rate}" 3 1
run_case "spike-${burst_rate}-no_hook" spike no_hook "${burst_rate}" 3 1

set_mode tap_xdp
run_openstack_status "${artifact_dir}/health/openstack-after.txt" || true
remote all 'for unit in kubelet containerd kubernetes-haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
  >"${artifact_dir}/health/kubernetes-after.txt"
remote node1 "systemctl is-active ${adapter_unit}; sudo -n bpftool net show dev ${client_tap}" \
  >"${artifact_dir}/health/adapter-after.txt"
backend_guest 'systemctl is-active linux-accel-openstack-dns-backend.service' \
  >"${artifact_dir}/health/backend-after.txt"

python3 "${repo_root}/tools/analyze_openstack_dns_bench.py" "${artifact_dir}" \
  >"${artifact_dir}/analysis-output.txt"
cat "${artifact_dir}/summary.md"
