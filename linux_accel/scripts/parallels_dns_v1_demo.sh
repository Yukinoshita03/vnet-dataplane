#!/usr/bin/env bash
set -euo pipefail

show_usage() {
  cat <<'EOF'
Usage: parallels_dns_v1_demo.sh [--vm NAME] [--dev IFACE] [--hook tc|xdp] [--xdp-mode native|generic] [--cache-domain NAME --cache-ip IPV4 [--cache-ttl SEC]] [--repo PATH] [--out DIR] [--duration SEC]

Defaults:
  --vm Ubuntu 24.04 ARM64
  --dev bond0
  --hook tc
  --xdp-mode native
  --cache-ttl 60
  --repo /home/parallels/ebpf-network-service-cache
  --out artifacts/dns-v1-demo
  --duration 60
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
local_repo="$(cd "${script_dir}/.." && pwd)"
vm_name="Ubuntu 24.04 ARM64"
dev_name="bond0"
hook="tc"
xdp_mode="native"
cache_domain=""
cache_ip=""
cache_ttl="60"
repo_path="/home/parallels/ebpf-network-service-cache"
out_root="artifacts/dns-v1-demo"
duration_sec="60"
vm_ip=""
guest_artifacts_root="/tmp/dns-v1-demo-artifacts"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)
      vm_name="${2:-}"
      shift 2
      ;;
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
    --repo)
      repo_path="${2:-}"
      shift 2
      ;;
    --out)
      out_root="${2:-}"
      shift 2
      ;;
    --duration)
      duration_sec="${2:-}"
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

if ! command -v prlctl >/dev/null 2>&1; then
  echo "prlctl is required on the host" >&2
  exit 1
fi

if ! prlctl list -a | grep -Fq "${vm_name}"; then
  echo "VM not found: ${vm_name}" >&2
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "ssh is required on the host" >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required on the host" >&2
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

timestamp="$(date +%Y%m%d-%H%M%S)"
host_out="${PWD}/${out_root}/${timestamp}"
mkdir -p "${host_out}"

if [[ ! -d "${local_repo}" ]]; then
  echo "Local repo not found: ${local_repo}" >&2
  exit 1
fi

vm_ip="$(ssh -o BatchMode=yes -o ConnectTimeout=5 parallels@10.211.55.6 'hostname -I | awk "{print \$1}"' 2>/dev/null || true)"
if [[ -z "${vm_ip}" ]]; then
  vm_ip="10.211.55.6"
fi

guest_out="${guest_artifacts_root}/${timestamp}"

{
  echo "vm=${vm_name}"
  echo "dev=${dev_name}"
  echo "hook=${hook}"
  echo "xdp_mode=${xdp_mode}"
  echo "cache_domain=${cache_domain}"
  echo "cache_ip=${cache_ip}"
  echo "cache_ttl=${cache_ttl}"
  echo "vm_ip=${vm_ip}"
  echo "repo=${repo_path}"
  echo "local_repo=${local_repo}"
  echo "duration=${duration_sec}"
  echo "timestamp=${timestamp}"
  echo "host_out=${host_out}"
  echo "guest_out=${guest_out}"
} | tee "${host_out}/host-env.log" >/dev/null

ssh -o BatchMode=yes -o ConnectTimeout=10 "parallels@${vm_ip}" "mkdir -p '${repo_path}' '${guest_out}'"

rsync -a --delete \
  --exclude '.git/' \
  --exclude 'build/' \
  --exclude 'artifacts/' \
  "${local_repo}/" \
  "parallels@${vm_ip}:${repo_path}/"

runner_args=(--dev "${dev_name}" --hook "${hook}" --xdp-mode "${xdp_mode}" --timeout-ms "1000" --duration "${duration_sec}" --out "${guest_out}")
if [[ -n "${cache_domain}" ]]; then
  runner_args+=(--cache-domain "${cache_domain}" --cache-ip "${cache_ip}" --cache-ttl "${cache_ttl}")
fi

set +e
prlctl exec "${vm_name}" /bin/bash "${repo_path}/scripts/dns_v1_demo_runner.sh" "${runner_args[@]}" | tee "${host_out}/demo.log"
remote_status=${PIPESTATUS[0]}
set -e

rsync -a "parallels@${vm_ip}:${guest_out}/" "${host_out}/" >/dev/null

if [[ "${remote_status}" -ne 0 ]]; then
  echo "Remote demo failed with exit code ${remote_status}" >&2
  exit "${remote_status}"
fi

echo "Artifacts copied to ${host_out}"
