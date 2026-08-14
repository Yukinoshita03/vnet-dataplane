#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_ssh="${CLUSTER_SSH:-/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-ssh.sh}"
cluster_copy="${CLUSTER_COPY:-/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-copy.sh}"
openstack_status="${OPENSTACK_STATUS:-/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/openstack-status.sh}"
qga_exec_tool="${repo_root}/tools/openstack_qga_exec.sh"
qga_copy_tool="${repo_root}/tools/openstack_qga_copy_to.sh"

artifact_dir="${1:?usage: $0 ARTIFACT_DIR [smoke|quick|full]}"
profile="${2:-quick}"
client_instance="${CLIENT_INSTANCE:-instance-0000000f}"
backend_instance="${BACKEND_INSTANCE:-instance-00000012}"
client_tap="${CLIENT_TAP:-tap96696c4a-57}"
backend_ip="${BACKEND_IP:-192.168.110.13}"
backend_port="${BACKEND_PORT:-19000}"
adapter_unit="${ADAPTER_UNIT:-linux-accel-openstack-tap-accel@96696c4a-5746-43ab-8137-241952309dac.service}"
release_dir="${UDP_RELEASE_DIR:-/opt/linux-accel-protocol-fastpath/current}"
udp_loader="${release_dir}/bin/udp_fastpath"
udp_bpf="${release_dir}/lib/bpf/udp_fastpath.bpf.o"
udp_bench_bin="${release_dir}/libexec/bench/udp_fastpath_bench"
guest_bench="/usr/local/bin/linux-accel-udp-bench"
run_id="$(basename "${artifact_dir}" | tr -cd 'A-Za-z0-9_.-')"
short_id="$(printf '%s' "${run_id}" | sha256sum | cut -c1-12)"
loader_unit_prefix="linux-accel-udp-xdp-${short_id}"
loader_unit=""
backend_unit="linux-accel-udp-backend-${short_id}.service"
remote_run="/tmp/linux-accel-udp-openstack-${short_id}"
remote_policy="${remote_run}/udp-policy.conf"
adapter_was_active=false
loader_started=false
backend_started=false

case "${profile}" in
  smoke)
    repetitions=1
    threads=2
    requests=500
    warmup=20
    ;;
  quick)
    repetitions=3
    threads=8
    requests=10000
    warmup=500
    ;;
  full)
    repetitions=5
    threads=16
    requests=50000
    warmup=2000
    ;;
  *)
    echo "profile must be smoke, quick or full" >&2
    exit 2
    ;;
esac

mkdir -p "${artifact_dir}/health" "${artifact_dir}/nohook" \
  "${artifact_dir}/xdp-miss" "${artifact_dir}/xdp"

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
  remote_payload node1 \
    "/tmp/linux-accel-qga-exec.sh ${client_instance} $(shell_quote "${command}")"
}

backend_guest()
{
  local command="$1"
  remote_payload node2 \
    "/tmp/linux-accel-qga-exec.sh ${backend_instance} $(shell_quote "${command}")"
}

run_openstack_status()
{
  local output="$1"
  "${openstack_status}" | tee "${output}"
}

stop_loader()
{
  if ${loader_started} && [[ -n "${loader_unit}" ]]; then
    remote node1 "sudo -n systemctl stop ${loader_unit} 2>/dev/null || true" \
      >/dev/null 2>&1 || true
    loader_started=false
  fi
}

stop_backend()
{
  if ${backend_started}; then
    backend_guest \
      "systemctl stop ${backend_unit} 2>/dev/null || true; true" \
      >/dev/null 2>&1 || true
    backend_started=false
  fi
}

restore_adapter()
{
  if ${adapter_was_active}; then
    remote node1 "sudo -n systemctl start ${adapter_unit}" >/dev/null 2>&1 || true
  fi
}

on_exit()
{
  local status=$?
  trap - EXIT INT TERM
  set +e
  stop_loader
  stop_backend
  restore_adapter
  exit "${status}"
}
trap on_exit EXIT INT TERM

run_client_case()
{
  local mode="$1"
  local repetition="$2"
  local output="${artifact_dir}/${mode}/rep-${repetition}.log"
  client_guest \
    "${guest_bench} --client ${backend_ip}:${backend_port} --threads ${threads} --requests ${requests} --warmup ${warmup}" \
    | tee "${output}"
  grep -q 'failed=0' "${output}"
}

metric()
{
  local file="$1"
  local name="$2"
  awk -v name="${name}" \
    '{for (i=1; i<=NF; i++) {split($i, a, "="); if (a[1] == name) {print a[2]; exit}}}' \
    "${file}"
}

median_metric()
{
  local mode="$1"
  local name="$2"
  local rank=$(( (repetitions + 1) / 2 ))
  for repetition in $(seq 1 "${repetitions}"); do
    metric "${artifact_dir}/${mode}/rep-${repetition}.log" "${name}"
  done | sort -g | sed -n "${rank}p"
}

run_openstack_status "${artifact_dir}/health/openstack-before.txt"
grep -Eq '^Horizon[[:space:]]+200$' \
  "${artifact_dir}/health/openstack-before.txt"
grep -Eq '^Keystone[[:space:]]+200$' \
  "${artifact_dir}/health/openstack-before.txt"
grep -Eq '^Neutron[[:space:]]+200$' \
  "${artifact_dir}/health/openstack-before.txt"

remote all \
  'for unit in kubelet containerd kubernetes-haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
  >"${artifact_dir}/health/kubernetes-before.txt"
if grep -q '=active$' "${artifact_dir}/health/kubernetes-before.txt"; then
  echo "Kubernetes must remain stopped during this benchmark" >&2
  exit 1
fi

remote node1 \
  "sudo -n bpftool net show; systemctl is-active ${adapter_unit} || true" \
  >"${artifact_dir}/health/attachments-before.txt"
if remote_payload node1 "systemctl is-active ${adapter_unit}" | tail -n 1 | \
    grep -qx active; then
  adapter_was_active=true
fi

"${cluster_copy}" "${qga_copy_tool}" /tmp/linux-accel-qga-copy-to.sh \
  node1 >/dev/null
"${cluster_copy}" "${qga_copy_tool}" /tmp/linux-accel-qga-copy-to.sh \
  node2 >/dev/null
"${cluster_copy}" "${qga_exec_tool}" /tmp/linux-accel-qga-exec.sh \
  node1 >/dev/null
"${cluster_copy}" "${qga_exec_tool}" /tmp/linux-accel-qga-exec.sh \
  node2 >/dev/null

remote node1 \
  "cd ${release_dir}; sha256sum -c SHA256SUMS; chmod 0755 /tmp/linux-accel-qga-copy-to.sh; /tmp/linux-accel-qga-copy-to.sh ${client_instance} ${udp_bench_bin} ${guest_bench} 0755" \
  >"${artifact_dir}/health/client-install.txt"
remote node2 \
  "cd ${release_dir}; sha256sum -c SHA256SUMS; chmod 0755 /tmp/linux-accel-qga-copy-to.sh; /tmp/linux-accel-qga-copy-to.sh ${backend_instance} ${udp_bench_bin} ${guest_bench} 0755" \
  >"${artifact_dir}/health/backend-install.txt"

backend_guest \
  "systemd-run --unit=${backend_unit} --collect --property=Type=simple -- ${guest_bench} --server 0.0.0.0:${backend_port}; for i in \$(seq 1 50); do systemctl is-active --quiet ${backend_unit} && exit 0; sleep 0.1; done; exit 1" \
  >"${artifact_dir}/health/backend-start.txt"
backend_started=true
client_guest "ping -c 2 -W 1 ${backend_ip}" \
  >"${artifact_dir}/health/client-ping.txt"

remote node1 \
  "sudo -n systemctl stop ${adapter_unit}; if sudo -n bpftool net show dev ${client_tap} 2>/dev/null | grep -Eq 'generic id|dns_client'; then exit 1; fi" \
  >"${artifact_dir}/health/nohook-state.txt"

for repetition in $(seq 1 "${repetitions}"); do
  echo "OpenStack UDP nohook repetition ${repetition}/${repetitions}"
  run_client_case nohook "${repetition}"
done

loader_unit="${loader_unit_prefix}-miss.service"
remote node1 \
  "test ! -e ${remote_run}; mkdir -p ${remote_run}; printf '%s\\n' '${client_tap} ${backend_ip} ${backend_port} 70696e68 706f6e672d6f6b 300' >${remote_policy}; sudo -n systemd-run --unit=${loader_unit} --collect --property=Type=simple -- ${udp_loader} --policy-file ${remote_policy} --bpf-object ${udp_bpf} --xdp-mode generic; for i in \$(seq 1 50); do state=\$(sudo -n bpftool net show dev ${client_tap} 2>/dev/null || true); if grep -q 'generic id' <<<\"\$state\" && systemctl is-active --quiet ${loader_unit}; then exit 0; fi; sleep 0.1; done; exit 1" \
  >"${artifact_dir}/health/loader-miss-start.txt"
loader_started=true

for repetition in $(seq 1 "${repetitions}"); do
  echo "OpenStack UDP XDP-miss repetition ${repetition}/${repetitions}"
  run_client_case xdp-miss "${repetition}"
done

remote node1 "sudo -n systemctl stop ${loader_unit}" >/dev/null
loader_started=false
remote node1 \
  "sudo -n journalctl --no-pager -o cat -u ${loader_unit}" \
  >"${artifact_dir}/loader-miss.log"
grep -Eq 'miss=[1-9][0-9]*' "${artifact_dir}/loader-miss.log"
if grep -Eq 'hit=[1-9][0-9]*' "${artifact_dir}/loader-miss.log"; then
  echo "The configured miss-path run unexpectedly produced a cache hit" >&2
  exit 1
fi

loader_unit="${loader_unit_prefix}-hit.service"
remote node1 \
  "printf '%s\\n' '${client_tap} ${backend_ip} ${backend_port} 70696e67 706f6e672d6f6b 300' >${remote_policy}; sudo -n systemd-run --unit=${loader_unit} --collect --property=Type=simple -- ${udp_loader} --policy-file ${remote_policy} --bpf-object ${udp_bpf} --xdp-mode generic; for i in \$(seq 1 50); do state=\$(sudo -n bpftool net show dev ${client_tap} 2>/dev/null || true); if grep -q 'generic id' <<<\"\$state\" && systemctl is-active --quiet ${loader_unit}; then exit 0; fi; sleep 0.1; done; exit 1" \
  >"${artifact_dir}/health/loader-start.txt"
loader_started=true

for repetition in $(seq 1 "${repetitions}"); do
  echo "OpenStack UDP XDP repetition ${repetition}/${repetitions}"
  run_client_case xdp "${repetition}"
done

remote node1 "sudo -n systemctl stop ${loader_unit}" >/dev/null
loader_started=false
remote node1 \
  "sudo -n journalctl --no-pager -o cat -u ${loader_unit}" \
  >"${artifact_dir}/loader.log"
grep -Eq 'hit=[1-9][0-9]*' "${artifact_dir}/loader.log"
grep -Eq 'tx=[1-9][0-9]*' "${artifact_dir}/loader.log"

backend_guest "systemctl stop ${backend_unit}" >/dev/null
backend_started=false
backend_guest "journalctl --no-pager -o cat -u ${backend_unit}" \
  >"${artifact_dir}/backend.log"

if ${adapter_was_active}; then
  restore_adapter
  remote node1 \
    "for i in \$(seq 1 50); do state=\$(sudo -n bpftool net show dev ${client_tap} 2>/dev/null || true); if grep -q 'generic id' <<<\"\$state\" && grep -q 'clsact/egress' <<<\"\$state\" && systemctl is-active --quiet ${adapter_unit}; then exit 0; fi; sleep 0.1; done; exit 1" \
    >"${artifact_dir}/health/adapter-restored.txt"
  adapter_was_active=false
else
  remote node1 \
    "if sudo -n bpftool net show dev ${client_tap} 2>/dev/null | grep -Eq 'generic id|dns_client'; then exit 1; fi" \
    >"${artifact_dir}/health/adapter-restored.txt"
fi

run_openstack_status "${artifact_dir}/health/openstack-after.txt"
remote all \
  'for unit in kubelet containerd kubernetes-haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done' \
  >"${artifact_dir}/health/kubernetes-after.txt"
if grep -q '=active$' "${artifact_dir}/health/kubernetes-after.txt"; then
  echo "Kubernetes unexpectedly became active" >&2
  exit 1
fi
remote node1 "sudo -n bpftool net show" \
  >"${artifact_dir}/health/attachments-after.txt"

nohook_qps="$(median_metric nohook qps)"
xdp_miss_qps="$(median_metric xdp-miss qps)"
xdp_qps="$(median_metric xdp qps)"
nohook_p99="$(median_metric nohook p99_us)"
xdp_miss_p99="$(median_metric xdp-miss p99_us)"
xdp_p99="$(median_metric xdp p99_us)"
qps_speedup="$(awk -v x="${xdp_qps}" -v b="${nohook_qps}" \
  'BEGIN {if (b > 0) printf "%.3f", x / b; else print "0"}')"
p99_speedup="$(awk -v x="${xdp_p99}" -v b="${nohook_p99}" \
  'BEGIN {if (x > 0) printf "%.3f", b / x; else print "0"}')"
miss_qps_ratio="$(awk -v x="${xdp_miss_qps}" -v b="${nohook_qps}" \
  'BEGIN {if (b > 0) printf "%.3f", x / b; else print "0"}')"
miss_p99_ratio="$(awk -v x="${xdp_miss_p99}" -v b="${nohook_p99}" \
  'BEGIN {if (b > 0) printf "%.3f", x / b; else print "0"}')"

{
  printf '# OpenStack TAP UDP fast-path benchmark\n\n'
  printf 'Profile: `%s`; repetitions: %s; threads: %s; requests/thread: %s.\n\n' \
    "${profile}" "${repetitions}" "${threads}" "${requests}"
  printf '| mode | median QPS | median p99 (us) |\n'
  printf '| --- | ---: | ---: |\n'
  printf '| no hook, backend VM | %s | %s |\n' \
    "${nohook_qps}" "${nohook_p99}"
  printf '| generic XDP miss, backend VM | %s | %s |\n' \
    "${xdp_miss_qps}" "${xdp_miss_p99}"
  printf '| generic XDP exact hit on client TAP | %s | %s |\n\n' \
    "${xdp_qps}" "${xdp_p99}"
  printf 'QPS speedup: %sx\n\n' "${qps_speedup}"
  printf 'p99 speedup (nohook/XDP): %sx\n\n' "${p99_speedup}"
  printf 'Miss-path QPS ratio (XDP/nohook): %sx\n\n' "${miss_qps_ratio}"
  printf 'Miss-path p99 ratio (XDP/nohook): %sx\n' "${miss_p99_ratio}"
} >"${artifact_dir}/summary.md"

trap - EXIT INT TERM
cat "${artifact_dir}/summary.md"
