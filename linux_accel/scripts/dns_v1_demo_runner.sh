#!/usr/bin/env bash
set -euo pipefail
umask 022

show_usage() {
  cat <<'EOF'
Usage: dns_v1_demo_runner.sh --dev IFACE [--hook tc|xdp] [--xdp-mode native|generic] [--cache-domain NAME --cache-ip IPV4 [--cache-ttl SEC]] [--timeout-ms MS] [--duration SEC] [--out DIR]

Defaults:
  --hook tc
  --xdp-mode native
  --cache-ttl 60
  --timeout-ms 1000
  --duration 60
  --out /tmp/dns-v1-demo
EOF
}

dev_name=""
hook="tc"
xdp_mode="native"
cache_domain=""
cache_ip=""
cache_ttl="60"
timeout_ms="1000"
duration_sec="60"
out_dir="/tmp/dns-v1-demo"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)
      dev_name="${2:-}"
      shift 2
      ;;
    --hook)
      hook="${2:-}"
      shift 2
      ;;
    --xdp-mode)
      xdp_mode="${2:-}"
      shift 2
      ;;
    --cache-domain)
      cache_domain="${2:-}"
      shift 2
      ;;
    --cache-ip)
      cache_ip="${2:-}"
      shift 2
      ;;
    --cache-ttl)
      cache_ttl="${2:-}"
      shift 2
      ;;
    --timeout-ms)
      timeout_ms="${2:-}"
      shift 2
      ;;
    --duration)
      duration_sec="${2:-}"
      shift 2
      ;;
    --out)
      out_dir="${2:-}"
      shift 2
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      show_usage
      exit 1
      ;;
  esac
done

if [[ -z "${dev_name}" ]]; then
  echo "--dev is required" >&2
  exit 1
fi

if [[ "${hook}" != "tc" && "${hook}" != "xdp" ]]; then
  echo "--hook must be tc or xdp" >&2
  exit 1
fi

if [[ "${xdp_mode}" != "native" && "${xdp_mode}" != "generic" ]]; then
  echo "--xdp-mode must be native or generic" >&2
  exit 1
fi

if [[ -n "${cache_domain}" || -n "${cache_ip}" ]]; then
  if [[ -z "${cache_domain}" || -z "${cache_ip}" ]]; then
    echo "--cache-domain and --cache-ip must be used together" >&2
    exit 1
  fi
  if [[ "${hook}" != "xdp" ]]; then
    echo "DNS cache options require --hook xdp" >&2
    exit 1
  fi
fi

for bin in clang c++ tc tcpdump dig bpftool; do
  command -v "${bin}" >/dev/null 2>&1 || {
    echo "Missing dependency: ${bin}" >&2
    exit 1
  }
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root inside the VM" >&2
  exit 1
fi

if ! ip link show "${dev_name}" >/dev/null 2>&1; then
  echo "Interface not found: ${dev_name}" >&2
  exit 1
fi

cd "${repo_root}"

work_dir="/tmp/dns-v1-demo-$(date +%s)"
mkdir -p "${work_dir}"
mkdir -p "${out_dir}"
stage_file="${work_dir}/stages.log"

cleanup() {
  if [[ -n "${dns_pid:-}" ]] && kill -0 "${dns_pid}" >/dev/null 2>&1; then
    kill "${dns_pid}" >/dev/null 2>&1 || true
    wait "${dns_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${tcpdump_pid:-}" ]] && kill -0 "${tcpdump_pid}" >/dev/null 2>&1; then
    kill "${tcpdump_pid}" >/dev/null 2>&1 || true
    wait "${tcpdump_pid}" >/dev/null 2>&1 || true
  fi
  tc qdisc del dev "${dev_name}" clsact >/dev/null 2>&1 || true
  tc filter show dev "${dev_name}" ingress > "${work_dir}/tc-after.log" 2>&1 || true
  tc filter show dev "${dev_name}" egress >> "${work_dir}/tc-after.log" 2>&1 || true
  if [[ -f "${work_dir}/dns_monitor.log" ]]; then
    cat "${work_dir}/dns_monitor.log"
  fi
  if [[ -f "${work_dir}/tcpdump.log" ]]; then
    cat "${work_dir}/tcpdump.log"
  fi
  if [[ -d "${out_dir}" ]]; then
    cp -a "${work_dir}/." "${out_dir}/" 2>/dev/null || true
    chmod -R a+rX "${out_dir}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

stage_log() {
  echo "[stage] $1" | tee -a "${stage_file}"
}

{
  hostname
  ip -br addr
  ip route
  resolvectl status || cat /etc/resolv.conf
  uname -a
} > "${work_dir}/env.log" 2>&1

stage_log "build"
./scripts/build_linux.sh > "${work_dir}/build.log" 2>&1

stage_log "attach"
tc qdisc add dev "${dev_name}" clsact >/dev/null 2>&1 || true
tc filter show dev "${dev_name}" ingress > "${work_dir}/tc-before.log" 2>&1 || true
tc filter show dev "${dev_name}" egress >> "${work_dir}/tc-before.log" 2>&1 || true

stage_log "start-monitor"
monitor_args=(--dev "${dev_name}" --hook "${hook}" --xdp-mode "${xdp_mode}" --timeout-ms "${timeout_ms}")
if [[ -n "${cache_domain}" ]]; then
  monitor_args+=(--cache-domain "${cache_domain}" --cache-ip "${cache_ip}" --cache-ttl "${cache_ttl}")
fi
./build/dns_monitor "${monitor_args[@]}" > "${work_dir}/dns_monitor.log" 2>&1 &
dns_pid="$!"

stage_log "start-tcpdump"
tcpdump -i "${dev_name}" udp port 53 -nn > "${work_dir}/tcpdump.log" 2>&1 &
tcpdump_pid="$!"

sleep 2

stage_log "resolve"
resolver_ip="$(
  resolvectl dns "${dev_name}" 2>/dev/null | awk 'NF {print $NF; exit}' || true
)"
if [[ -z "${resolver_ip}" ]]; then
  resolver_ip="$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
fi

if [[ -n "${resolver_ip}" ]]; then
  if [[ -n "${cache_domain}" ]]; then
    stage_log "query-cache-domain"
    dig +noedns @"${resolver_ip}" "${cache_domain}" > "${work_dir}/dig-cache-domain.log" 2>&1 || true
  fi
  stage_log "query-normal"
  dig @"${resolver_ip}" example.com > "${work_dir}/dig-normal.log" 2>&1 || true
  stage_log "query-nxdomain"
  dig @"${resolver_ip}" nonexistent-domain-for-test.example > "${work_dir}/dig-nxdomain.log" 2>&1 || true
else
  if [[ -n "${cache_domain}" ]]; then
    stage_log "query-cache-domain"
    dig +noedns "${cache_domain}" > "${work_dir}/dig-cache-domain.log" 2>&1 || true
  fi
  stage_log "query-normal"
  dig example.com > "${work_dir}/dig-normal.log" 2>&1 || true
  stage_log "query-nxdomain"
  dig nonexistent-domain-for-test.example > "${work_dir}/dig-nxdomain.log" 2>&1 || true
fi

stage_log "query-timeout"
dig @192.0.2.1 example.com +time=1 +tries=1 > "${work_dir}/dig-timeout.log" 2>&1 || true

if command -v dnsperf >/dev/null 2>&1; then
  stage_log "load-dnsperf"
  printf "example.com\n" > "${work_dir}/query.txt"
  dnsperf -s "${resolver_ip:-192.0.2.1}" -d "${work_dir}/query.txt" -l "${duration_sec}" > "${work_dir}/load.log" 2>&1 || true
else
  stage_log "load-fallback"
  dig_pids=()
  for i in $(seq 1 100); do
    dig example.com >/dev/null 2>&1 &
    dig_pids+=("$!")
  done
  for pid in "${dig_pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done
  echo "dnsperf not installed, used parallel dig fallback" > "${work_dir}/load.log"
fi

sleep 2

stage_log "bpftool"
bpftool prog show > "${work_dir}/bpftool.log" 2>&1 || true
bpftool map show >> "${work_dir}/bpftool.log" 2>&1 || true

stage_log "stop-monitor"
kill "${dns_pid}" >/dev/null 2>&1 || true
wait "${dns_pid}" >/dev/null 2>&1 || true
dns_pid=""

stage_log "stop-tcpdump"
kill "${tcpdump_pid}" >/dev/null 2>&1 || true
wait "${tcpdump_pid}" >/dev/null 2>&1 || true
tcpdump_pid=""

stage_log "cleanup"
cleanup

echo "work_dir=${work_dir}"
echo "out_dir=${out_dir}"
for file in env.log build.log tc-before.log tc-after.log dig-cache-domain.log dig-normal.log dig-nxdomain.log dig-timeout.log load.log bpftool.log dns_monitor.log tcpdump.log; do
  if [[ -f "${work_dir}/${file}" ]]; then
    echo "--- ${file}"
    cat "${work_dir}/${file}"
  fi
done
