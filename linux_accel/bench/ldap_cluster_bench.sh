#!/usr/bin/env bash
set -Eeuo pipefail

cluster_ssh="${CLUSTER_SSH:-/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-ssh.sh}"
openstack_status="${OPENSTACK_STATUS:-/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/openstack-status.sh}"
artifact_dir="${1:?usage: $0 ARTIFACT_DIR [smoke|quick|full]}"
profile="${2:-quick}"
release_dir="${LDAP_RELEASE_DIR:-/opt/linux-accel-protocol-fastpath/current}"
ldap_proxy_bin="${release_dir}/bin/ldap_sockmap_proxy"
ldap_bpf="${release_dir}/lib/bpf/ldap_sockmap.bpf.o"
ldap_bench_bin="${release_dir}/libexec/bench/ldap_bench"
client_node="${LDAP_CLIENT_NODE:-node2}"
proxy_node="${LDAP_PROXY_NODE:-node1}"
backend_node="${LDAP_BACKEND_NODE:-node3}"
proxy_ip="${LDAP_PROXY_IP:-10.115.24.245}"
backend_ip="${LDAP_BACKEND_IP:-10.115.24.40}"
proxy_backend_ip="${LDAP_PROXY_BACKEND_IP:-${backend_ip}}"
response_bytes="${LDAP_RESPONSE_BYTES:-4096}"
pipeline="${LDAP_PIPELINE:-1}"
timeout_ms="${LDAP_TIMEOUT_MS:-5000}"
skip_openstack_status="${LDAP_SKIP_OPENSTACK_STATUS:-0}"
run_id="$(basename "${artifact_dir}" | tr -cd 'A-Za-z0-9_.-')"
short_id="$(printf '%s' "${run_id}" | sha256sum | cut -c1-12)"
port_seed="$(printf '%s' "${short_id}" | cut -c1-3)"
base_port=$((42000 + (16#${port_seed} % 1000)))
backend_port="${LDAP_BACKEND_PORT:-${base_port}}"
backend_unit="linux-accel-ldap-backend-${short_id}.service"
proxy_unit=""
backend_started=false
proxy_started=false

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
    requests=20000
    warmup=200
    ;;
  full)
    repetitions=5
    threads=32
    requests=20000
    warmup=500
    ;;
  *)
    echo "profile must be smoke, quick or full" >&2
    exit 2
    ;;
esac

repetitions="${LDAP_REPETITIONS:-${repetitions}}"
threads="${LDAP_THREADS:-${threads}}"
requests="${LDAP_REQUESTS:-${requests}}"
warmup="${LDAP_WARMUP:-${warmup}}"

mkdir -p "${artifact_dir}/health" "${artifact_dir}/direct" \
  "${artifact_dir}/userspace" "${artifact_dir}/splice" \
  "${artifact_dir}/sockmap" "${artifact_dir}/host-stats"

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

run_openstack_status()
{
  local output="$1"
  "${openstack_status}" | tee "${output}"
}

stop_proxy()
{
  if ${proxy_started} && [[ -n "${proxy_unit}" ]]; then
    remote "${proxy_node}" "sudo -n systemctl stop ${proxy_unit} 2>/dev/null || true" \
      >/dev/null 2>&1 || true
    proxy_started=false
  fi
}

stop_backend()
{
  if ${backend_started}; then
    remote "${backend_node}" "sudo -n systemctl stop ${backend_unit} 2>/dev/null || true" \
      >/dev/null 2>&1 || true
    backend_started=false
  fi
}

on_exit()
{
  local status=$?
  trap - EXIT INT TERM
  set +e
  stop_proxy
  stop_backend
  exit "${status}"
}
trap on_exit EXIT INT TERM

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
  for repetition in $(seq 1 "${repetitions}"); do
    metric "${artifact_dir}/${mode}/rep-${repetition}.log" "${name}"
  done | sort -g | awk '
    { values[NR] = $1 }
    END {
      if (NR == 0) exit 1
      if (NR % 2 == 1) print values[(NR + 1) / 2]
      else printf "%.6f\n", (values[NR / 2] + values[NR / 2 + 1]) / 2
    }'
}

capture_host_stats()
{
  local mode="$1"
  local phase="$2"
  remote "${proxy_node}" \
    "echo '[proc-stat]'; cat /proc/stat; echo '[softirqs]'; cat /proc/softirqs; echo '[softnet]'; cat /proc/net/softnet_stat" \
    >"${artifact_dir}/host-stats/${mode}-${phase}.txt"
}

capture_proxy_stat()
{
  local mode="$1"
  local phase="$2"
  remote_payload "${proxy_node}" \
    "pid=\$(sudo -n systemctl show -p MainPID --value ${proxy_unit}); test \"\$pid\" -gt 0; sudo -n cat /proc/\$pid/stat" \
    >"${artifact_dir}/${mode}/proxy-stat-${phase}.txt"
}

run_client()
{
  local mode="$1"
  local target="$2"
  local repetition="$3"
  local output="${artifact_dir}/${mode}/rep-${repetition}.log"
  remote_payload "${client_node}" \
    "${ldap_bench_bin} --client ${target} --threads ${threads} --requests ${requests} --warmup ${warmup} --response-bytes ${response_bytes} --pipeline ${pipeline} --timeout-ms ${timeout_ms}" \
    | tee "${output}"
  grep -q 'failed=0' "${output}"
}

start_proxy()
{
  local mode="$1"
  local port="$2"
  proxy_unit="linux-accel-ldap-${mode}-${short_id}.service"
  local bpf_args=""
  if [[ "${mode}" == sockmap ]]; then
    bpf_args="--bpf-object ${ldap_bpf}"
  fi
  remote "${proxy_node}" \
    "if sudo -n ss -ltnp | grep -qE ':${port}\\b'; then echo 'proxy port in use' >&2; exit 1; fi; sudo -n systemd-run --unit=${proxy_unit} --collect --property=Type=simple -- ${ldap_proxy_bin} --listen 0.0.0.0:${port} --backend ${proxy_backend_ip}:${backend_port} --mode ${mode} ${bpf_args}; for i in \$(seq 1 50); do if sudo -n systemctl is-active --quiet ${proxy_unit} && sudo -n ss -ltnp | grep -qE ':${port}\\b'; then exit 0; fi; sleep 0.1; done; exit 1" \
    >"${artifact_dir}/${mode}/proxy-start.log"
  proxy_started=true
}

run_proxy_mode()
{
  local mode="$1"
  local port="$2"
  start_proxy "${mode}" "${port}"
  capture_proxy_stat "${mode}" start
  capture_host_stats "${mode}" start
  for repetition in $(seq 1 "${repetitions}"); do
    echo "LDAP ${mode} repetition ${repetition}/${repetitions}"
    run_client "${mode}" "${proxy_ip}:${port}" "${repetition}"
  done
  capture_host_stats "${mode}" end
  capture_proxy_stat "${mode}" end
  remote "${proxy_node}" "sudo -n systemctl stop ${proxy_unit}" >/dev/null
  proxy_started=false
  remote "${proxy_node}" "sudo -n journalctl --no-pager -o cat -u ${proxy_unit}" \
    >"${artifact_dir}/${mode}/proxy.log"
  grep -Eq 'relay_error=0($| )' "${artifact_dir}/${mode}/proxy.log"
  case "${mode}" in
    userspace)
      grep -Eq 'userspace_bytes=[1-9][0-9]*' \
        "${artifact_dir}/${mode}/proxy.log"
      ;;
    splice)
      grep -Eq 'splice_bytes=[1-9][0-9]*' \
        "${artifact_dir}/${mode}/proxy.log"
      ;;
    sockmap)
      grep -Eq 'sockmap_pairs=[1-9][0-9]*' \
        "${artifact_dir}/${mode}/proxy.log"
      grep -Eq 'fallback_bytes=0($| )' \
        "${artifact_dir}/${mode}/proxy.log"
      grep -Eq 'redirect_fail=0($| )' \
        "${artifact_dir}/${mode}/proxy.log"
      ;;
  esac
}

cpu_seconds()
{
  local mode="$1"
  local ticks
  ticks="$(awk 'NR == 1 {start=$14+$15; next} NR == 2 {print $14+$15-start}' \
    "${artifact_dir}/${mode}/proxy-stat-start.txt" \
    "${artifact_dir}/${mode}/proxy-stat-end.txt")"
  awk -v ticks="${ticks}" -v hz="${clk_tck}" \
    'BEGIN {printf "%.2f", ticks / hz}'
}

if [[ "${skip_openstack_status}" == 1 ]]; then
  printf 'skipped: LDAP_SKIP_OPENSTACK_STATUS=1\n' \
    >"${artifact_dir}/health/openstack-before.txt"
else
  run_openstack_status "${artifact_dir}/health/openstack-before.txt"
fi

participant_nodes=("${client_node}" "${proxy_node}" "${backend_node}")

for node in "${participant_nodes[@]}"; do
  remote "${node}" \
    'for unit in kubelet containerd kubernetes-haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done'
done >"${artifact_dir}/health/kubernetes-before.txt"
if grep -q '=active$' "${artifact_dir}/health/kubernetes-before.txt"; then
  echo "Kubernetes must remain stopped during this benchmark" >&2
  exit 1
fi

for node in "${participant_nodes[@]}"; do
  remote "${node}" "cd ${release_dir}; sha256sum -c SHA256SUMS" \
    >"${artifact_dir}/health/${node}-release.txt"
done

clk_tck="$(remote_payload "${proxy_node}" 'getconf CLK_TCK' | tail -n 1)"
[[ "${clk_tck}" =~ ^[0-9]+$ ]]

remote "${backend_node}" \
  "if sudo -n ss -ltnp | grep -qE ':${backend_port}\\b'; then echo 'backend port in use' >&2; exit 1; fi; sudo -n systemd-run --unit=${backend_unit} --collect --property=Type=simple -- ${ldap_bench_bin} --server 0.0.0.0:${backend_port} --response-bytes ${response_bytes}; for i in \$(seq 1 50); do if sudo -n systemctl is-active --quiet ${backend_unit} && sudo -n ss -ltnp | grep -qE ':${backend_port}\\b'; then exit 0; fi; sleep 0.1; done; exit 1" \
  >"${artifact_dir}/health/backend-start.txt"
backend_started=true

for repetition in $(seq 1 "${repetitions}"); do
  echo "LDAP direct repetition ${repetition}/${repetitions}"
  run_client direct "${backend_ip}:${backend_port}" "${repetition}"
done

run_proxy_mode userspace $((base_port + 1))
run_proxy_mode splice $((base_port + 2))
run_proxy_mode sockmap $((base_port + 3))

remote "${backend_node}" "sudo -n systemctl stop ${backend_unit}" >/dev/null
backend_started=false
remote "${backend_node}" "sudo -n journalctl --no-pager -o cat -u ${backend_unit}" \
  >"${artifact_dir}/backend.log"

if [[ "${skip_openstack_status}" == 1 ]]; then
  printf 'skipped: LDAP_SKIP_OPENSTACK_STATUS=1\n' \
    >"${artifact_dir}/health/openstack-after.txt"
else
  run_openstack_status "${artifact_dir}/health/openstack-after.txt"
fi
for node in "${participant_nodes[@]}"; do
  remote "${node}" \
    'for unit in kubelet containerd kubernetes-haproxy; do printf "%s=%s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done'
done >"${artifact_dir}/health/kubernetes-after.txt"
if grep -q '=active$' "${artifact_dir}/health/kubernetes-after.txt"; then
  echo "Kubernetes unexpectedly became active" >&2
  exit 1
fi

direct_qps="$(median_metric direct qps)"
direct_p99="$(median_metric direct p99_us)"
userspace_qps="$(median_metric userspace qps)"
userspace_p99="$(median_metric userspace p99_us)"
splice_qps="$(median_metric splice qps)"
splice_p99="$(median_metric splice p99_us)"
sockmap_qps="$(median_metric sockmap qps)"
sockmap_p99="$(median_metric sockmap p99_us)"
userspace_cpu="$(cpu_seconds userspace)"
splice_cpu="$(cpu_seconds splice)"
sockmap_cpu="$(cpu_seconds sockmap)"

ratio()
{
  awk -v value="$1" -v baseline="$2" \
    'BEGIN {if (baseline > 0) printf "%.3f", value / baseline; else print "0"}'
}

{
  printf '# LDAP transport benchmark\n\n'
  printf 'Profile: `%s`; repetitions: %s; threads: %s; requests/thread: %s; response: %s bytes.\n\n' \
    "${profile}" "${repetitions}" "${threads}" "${requests}" \
    "${response_bytes}"
  printf 'Topology: client `%s` -> proxy `%s` (%s) -> backend `%s` (%s); proxy-to-backend address `%s`.\n\n' \
    "${client_node}" "${proxy_node}" "${proxy_ip}" "${backend_node}" \
    "${backend_ip}" "${proxy_backend_ip}"
  printf '| path | median QPS | median p99 (us) | QPS/userspace | userspace p99/current p99 | proxy CPU seconds |\n'
  printf '| --- | ---: | ---: | ---: | ---: | ---: |\n'
  printf '| direct | %s | %s | — | — | — |\n' \
    "${direct_qps}" "${direct_p99}"
  printf '| userspace | %s | %s | 1.000x | 1.000x | %s |\n' \
    "${userspace_qps}" "${userspace_p99}" "${userspace_cpu}"
  printf '| splice | %s | %s | %sx | %sx | %s |\n' \
    "${splice_qps}" "${splice_p99}" \
    "$(ratio "${splice_qps}" "${userspace_qps}")" \
    "$(ratio "${userspace_p99}" "${splice_p99}")" "${splice_cpu}"
  printf '| sockmap | %s | %s | %sx | %sx | %s |\n' \
    "${sockmap_qps}" "${sockmap_p99}" \
    "$(ratio "${sockmap_qps}" "${userspace_qps}")" \
    "$(ratio "${userspace_p99}" "${sockmap_p99}")" "${sockmap_cpu}"
} >"${artifact_dir}/summary.md"

trap - EXIT INT TERM
cat "${artifact_dir}/summary.md"
