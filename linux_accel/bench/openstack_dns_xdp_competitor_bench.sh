#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_ssh="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-ssh.sh"
cluster_copy="/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-copy.sh"
qga_exec_tool="${repo_root}/tools/openstack_qga_exec.sh"
qga_copy_tool="${repo_root}/tools/openstack_qga_copy_to.sh"

artifact_dir="${1:?usage: $0 ARTIFACT_DIR CORPUS_DIR REMOTE_RELEASE}"
corpus_dir="${2:?usage: $0 ARTIFACT_DIR CORPUS_DIR REMOTE_RELEASE}"
remote_release="${3:?usage: $0 ARTIFACT_DIR CORPUS_DIR REMOTE_RELEASE}"
rate="${RATE:-20000}"
duration="${DURATION:-5}"
repetitions="${REPETITIONS:-3}"

client_instance="instance-0000000f"
backend_instance="instance-00000012"
client_tap="tap96696c4a-57"
backend_ip="192.168.110.13"
adapter_unit="linux-accel-openstack-tap-accel@96696c4a-5746-43ab-8137-241952309dac.service"
token="$(basename "${artifact_dir}" | tr -cd 'a-zA-Z0-9-' | cut -c1-32)"
backend_unit="linux-accel-competitor-backend-${token}"
xpress_unit="linux-accel-xpress-${token}"
linux_unit="linux-accel-direct-${token}"
query_guest="/tmp/${token}-queries.txt"
correctness_guest="/tmp/${token}-correctness.py"
backend_guest_script="/tmp/${token}-backend.py"
cache_remote="/tmp/${token}-cache.txt"
queries_remote="/tmp/${token}-queries.txt"
original_adapter_active=0
backend_replaced=0

for path in "${corpus_dir}/queries.txt" "${corpus_dir}/cache.txt" \
  "${corpus_dir}/corpus-manifest.json"; do
  test -s "${path}"
done
for command in jq python3; do
  command -v "${command}" >/dev/null
done
mkdir -p "${artifact_dir}"/{health,correctness,cases,logs}

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

wait_no_experiment_xdp()
{
  remote node1 "for i in \$(seq 1 80); do state=\$(sudo -n bpftool net show dev ${client_tap} 2>/dev/null || true); if ! grep -Eq '(generic|native|offload) id [0-9]+' <<<\"\$state\"; then exit 0; fi; sleep 0.1; done; echo \"\$state\"; exit 1" >/dev/null
}

wait_generic_xdp()
{
  local unit="$1"
  if ! remote node1 "for i in \$(seq 1 100); do state=\$(sudo -n bpftool net show dev ${client_tap} 2>/dev/null || true); if grep -Eq 'generic id [0-9]+' <<<\"\$state\"; then exit 0; fi; sudo -n systemctl is-active --quiet ${unit} || break; sleep 0.1; done; sudo -n systemctl status --no-pager ${unit} || true; sudo -n journalctl -u ${unit} --no-pager -n 80; exit 1" >/dev/null; then
    return 1
  fi
}

stop_experiment_hooks()
{
  remote node1 "sudo -n systemctl stop ${xpress_unit} ${linux_unit} 2>/dev/null || true; sudo -n systemctl reset-failed ${xpress_unit} ${linux_unit} 2>/dev/null || true" >/dev/null || true
  wait_no_experiment_xdp || true
}

restore()
{
  set +e
  stop_experiment_hooks
  if [ "${original_adapter_active}" -eq 1 ]; then
    remote node1 "sudo -n systemctl start ${adapter_unit}" >/dev/null 2>&1
  fi
  if [ "${backend_replaced}" -eq 1 ]; then
    backend_guest "systemctl stop ${backend_unit} 2>/dev/null || true; systemctl reset-failed ${backend_unit} 2>/dev/null || true; systemctl start linux-accel-openstack-dns-backend.service"
  fi
}

on_exit()
{
  local status=$?
  trap - EXIT INT TERM
  restore
  exit "${status}"
}
trap on_exit EXIT INT TERM

backend_snapshot()
{
  backend_guest "pid=\$(systemctl show -p MainPID --value ${backend_unit}); kill -USR1 \"\$pid\"; sleep 0.2; cat /run/${token}-backend.json" | tail -n 1
}

set_mode()
{
  local mode="$1"
  stop_experiment_hooks
  case "${mode}" in
    nohook)
      ;;
    xpress)
      remote node1 "sudo -n systemd-run --unit=${xpress_unit} --collect --property=KillSignal=SIGTERM --property=TimeoutStopSec=5 /usr/bin/taskset -c 11 ${remote_release}/linux-accel/build/radar-dns-xdp-competitor/xpress_dns_loader --dev ${client_tap} --xdp-mode generic --bpf-object ${remote_release}/linux-accel/build/radar-dns-xdp-competitor/xpress_dns.bpf.o --cache-file ${cache_remote}" >/dev/null
      wait_generic_xdp "${xpress_unit}"
      ;;
    linux-accel)
      remote node1 "sudo -n systemd-run --unit=${linux_unit} --collect --property=KillSignal=SIGTERM --property=TimeoutStopSec=5 /usr/bin/taskset -c 11 ${remote_release}/linux-accel/build/dns_monitor --dev ${client_tap} --hook xdp --role server --xdp-mode generic --bpf-object ${remote_release}/linux-accel/build/dns_xdp_monitor.bpf.o --cache-file ${cache_remote}" >/dev/null
      wait_generic_xdp "${linux_unit}"
      ;;
    *)
      echo "unknown mode ${mode}" >&2
      return 2
      ;;
  esac
  remote_payload node1 "sudo -n bpftool net show dev ${client_tap} 2>/dev/null || true" \
    >"${artifact_dir}/logs/${mode}-attachment-$(date +%s%N).txt"
}

run_correctness()
{
  local mode="$1" before after delta expected
  set_mode "${mode}"
  before="$(backend_snapshot)"
  client_guest "python3 ${correctness_guest} --server ${backend_ip} --domain radar.example.test --answer 10.0.0.123" \
    >"${artifact_dir}/correctness/${mode}.json"
  after="$(backend_snapshot)"
  delta="$(jq -n --argjson before "${before}" --argjson after "${after}" '$after.requests - $before.requests')"
  case "${mode}" in
    nohook) expected=14 ;;
    xpress) expected=13 ;;
    linux-accel) expected=11 ;;
  esac
  jq -e '.passed == true' "${artifact_dir}/correctness/${mode}.json" >/dev/null
  test "${delta}" -eq "${expected}"
  printf 'mode=%s backend_delta=%s expected=%s\n' "${mode}" "${delta}" "${expected}" \
    >"${artifact_dir}/correctness/${mode}-backend.txt"
}

run_case()
{
  local mode="$1" repetition="$2" directory before after
  directory="${artifact_dir}/cases/${mode}-r${repetition}"
  mkdir -p "${directory}"
  set_mode "${mode}"
  client_guest "LC_ALL=C dnsperf -s ${backend_ip} -p 53 -d ${query_guest} -l 1 -Q 1000 -q 4096 -T 2 -c 8 -t 1 >/dev/null 2>&1"
  before="$(backend_snapshot)"
  printf '%s\n' "${before}" >"${directory}/backend-before.json"
  client_guest "LC_ALL=C /usr/bin/time -v dnsperf -s ${backend_ip} -p 53 -d ${query_guest} -l ${duration} -Q ${rate} -q 20000 -T 2 -c 8 -t 1 -S 1 -O latency-histogram 2>&1" \
    >"${directory}/dnsperf.log"
  after="$(backend_snapshot)"
  printf '%s\n' "${after}" >"${directory}/backend-after.json"
  python3 "${repo_root}/tools/parse_dnsperf.py" "${directory}/dnsperf.log" \
    >"${directory}/dnsperf.json"
  jq -n --arg mode "${mode}" --argjson repetition "${repetition}" \
    --argjson rate "${rate}" --argjson duration "${duration}" \
    --argjson before "${before}" --argjson after "${after}" \
    '{mode:$mode,repetition:$repetition,offered_qps:$rate,duration_seconds:$duration,backend_delta:($after.requests-$before.requests)}' \
    >"${directory}/metadata.json"
  jq -e '.completion_percent >= 99.5' "${directory}/dnsperf.json" >/dev/null
}

remote all 'for unit in kubelet k3s rke2-server rke2-agent; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
  >"${artifact_dir}/health/kubernetes-before.txt"
if grep -q '=active$' "${artifact_dir}/health/kubernetes-before.txt"; then
  echo "Kubernetes must remain stopped" >&2
  exit 1
fi

"${cluster_copy}" "${qga_exec_tool}" /tmp/linux-accel-qga-exec.sh node1 >/dev/null
"${cluster_copy}" "${qga_exec_tool}" /tmp/linux-accel-qga-exec.sh node2 >/dev/null
"${cluster_copy}" "${qga_copy_tool}" /tmp/linux-accel-qga-copy-to.sh node1 >/dev/null
"${cluster_copy}" "${qga_copy_tool}" /tmp/linux-accel-qga-copy-to.sh node2 >/dev/null
"${cluster_copy}" "${corpus_dir}/queries.txt" "${queries_remote}" node1 >/dev/null
"${cluster_copy}" "${corpus_dir}/cache.txt" "${cache_remote}" node1 >/dev/null
"${cluster_copy}" "${repo_root}/bench/radar_dns_correctness.py" "/tmp/${token}-correctness.py" node1 >/dev/null
"${cluster_copy}" "${repo_root}/bench/openstack_dns_backend.py" "/tmp/${token}-backend.py" node2 >/dev/null
remote node1 "chmod 0755 /tmp/linux-accel-qga-exec.sh /tmp/linux-accel-qga-copy-to.sh; /tmp/linux-accel-qga-copy-to.sh ${client_instance} ${queries_remote} ${query_guest} 0644; /tmp/linux-accel-qga-copy-to.sh ${client_instance} /tmp/${token}-correctness.py ${correctness_guest} 0755" >/dev/null
remote node2 "chmod 0755 /tmp/linux-accel-qga-exec.sh /tmp/linux-accel-qga-copy-to.sh; /tmp/linux-accel-qga-copy-to.sh ${backend_instance} /tmp/${token}-backend.py ${backend_guest_script} 0755" >/dev/null

if remote node1 "systemctl is-active --quiet ${adapter_unit}" >/dev/null 2>&1; then
  original_adapter_active=1
fi
remote node1 "sudo -n systemctl stop ${adapter_unit}" >/dev/null
wait_no_experiment_xdp

backend_guest "systemctl stop linux-accel-openstack-dns-backend.service; systemd-run --unit=${backend_unit} --collect /usr/bin/python3 ${backend_guest_script} --bind ${backend_ip} --port 53 --domain radar.example.test --answer 10.0.0.123 --ttl 3600 --count-file /run/${token}-backend.json; for i in \$(seq 1 50); do systemctl is-active --quiet ${backend_unit} && exit 0; sleep 0.1; done; systemctl status --no-pager ${backend_unit}; exit 1"
backend_replaced=1
client_guest "command -v dnsperf; test \$(wc -l < ${query_guest}) -eq 50000; ping -c 2 -W 1 ${backend_ip}"

cp "${corpus_dir}/corpus-manifest.json" "${artifact_dir}/corpus-manifest.json"
{
  echo "topology=OpenStack client VM/TAP -> OVN/OVS/Geneve -> backend VM"
  echo "hook=${client_tap} generic XDP"
  echo "rate=${rate}"
  echo "duration=${duration}"
  echo "repetitions=${repetitions}"
  echo "xpress_commit=312e2a30c7838be0c5b92ab5d302a04a55f5afcd"
  echo "remote_release=${remote_release}"
  echo "queries_sha256=$(shasum -a 256 "${corpus_dir}/queries.txt" | awk '{print $1}')"
  echo "cache_sha256=$(shasum -a 256 "${corpus_dir}/cache.txt" | awk '{print $1}')"
} >"${artifact_dir}/metadata.txt"

for mode in nohook xpress linux-accel; do
  run_correctness "${mode}"
done

for repetition in $(seq 1 "${repetitions}"); do
  case "${repetition}" in
    1) modes=(nohook xpress linux-accel) ;;
    2) modes=(linux-accel xpress nohook) ;;
    *) modes=(xpress nohook linux-accel) ;;
  esac
  for mode in "${modes[@]}"; do
    run_case "${mode}" "${repetition}"
  done
done

stop_experiment_hooks
for unit in "${xpress_unit}" "${linux_unit}"; do
  remote_payload node1 "sudo -n journalctl -u ${unit} --no-pager || true" \
    >"${artifact_dir}/logs/${unit}.log"
done
remote all 'for unit in kubelet k3s rke2-server rke2-agent; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
  >"${artifact_dir}/health/kubernetes-after.txt"
cmp -s "${artifact_dir}/health/kubernetes-before.txt" \
  "${artifact_dir}/health/kubernetes-after.txt"
echo "artifacts=${artifact_dir}"
