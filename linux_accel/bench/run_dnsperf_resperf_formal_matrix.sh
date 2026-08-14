#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${RELEASE_DIR:-/opt/competitor-bench/releases/competitor-preflight-20260813-173626/dns-radar-v11}"
linux_dir="${LINUX_DIR:-${release_dir}/linux-accel}"
xpress_src="${XPRESS_SRC:-${release_dir}/xpress-patched}"
benchmark="${BENCHMARK:-${linux_dir}/bench/radar_dns_xdp_competitor_bench.sh}"
dnsperf_root="${DNSPERF_ROOT:-/opt/competitor-bench/tools/dnsperf-2.15.1/install}"
run_id="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
result_root="${RESULT_ROOT:-/opt/competitor-bench/results/competitor-preflight-20260813-173626/dnsperf-resperf-formal-${run_id}}"
formal_repetitions="${FORMAL_REPETITIONS:-6}"
resperf_repetitions="${RESPERF_REPETITIONS:-3}"

if (( EUID != 0 )); then
  echo "run as root" >&2
  exit 1
fi
test -x "${benchmark}"
test -f "${xpress_src}/src/xdp_dns_kern.c"
test -x "${dnsperf_root}/bin/dnsperf"
test -x "${dnsperf_root}/bin/resperf"
test ! -e "${result_root}"
mkdir -p "${result_root}"

health_guard()
{
  local unit
  for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
    if [[ "$(systemctl is-active "${unit}" 2>/dev/null || true)" == active ]]; then
      echo "Kubernetes unit unexpectedly active: ${unit}" >&2
      exit 1
    fi
  done
  if bpftool net show | grep -Eq '(generic|native|offload) id'; then
    echo "unexpected XDP program remains attached" >&2
    exit 1
  fi
}

run_profile()
{
  local name="$1" rate="$2" duration="$3" with_resperf="$4"
  health_guard
  env XPRESS_SRC="${xpress_src}" \
    XPRESS_COMMIT=312e2a30c7838be0c5b92ab5d302a04a55f5afcd \
    BUILD_DIR="${linux_dir}/build/radar-dns-xdp-competitor" \
    OUT_DIR="${result_root}/${name}" \
    REPETITIONS="${formal_repetitions}" RATE="${rate}" DURATION="${duration}" \
    THREADS=6 BATCH=32 CPU_BASE=0 CONTROL_CPU=8 BACKEND_CPU=10 \
    TIMEOUT_US=50000 WARMUP_DURATION=1 \
    CORPUS_PROFILE=radar-nl-observed CORPUS_LINES=50000 \
    WORKLOAD_PROFILE="${name}" \
    SOURCE_PROFILE=Cloudflare-Radar-NL-observed-marginals \
    CLIENT_TOOL=dnsperf \
    DNSPERF_BIN="${dnsperf_root}/bin/dnsperf" DNSPERF_VERSION=2.15.1 \
    DNSPERF_CLIENTS=8 DNSPERF_THREADS=4 DNSPERF_OUTSTANDING=20000 \
    DNSPERF_CPU_LIST=0-7 \
    RUN_RESPERF="${with_resperf}" \
    RESPERF_BIN="${dnsperf_root}/bin/resperf" RESPERF_VERSION=2.15.1 \
    RESPERF_REPETITIONS="${resperf_repetitions}" \
    RESPERF_RAMP=15 RESPERF_MAX_QPS=650000 \
    RESPERF_CLIENTS=8 RESPERF_OUTSTANDING=65536 RESPERF_CPU_LIST=0-7 \
    "${benchmark}"
  health_guard
}

{
  echo "run_id=${run_id}"
  echo "release_dir=${release_dir}"
  echo "dnsperf_version=2.15.1"
  echo "dnsperf_source_sha256=4d64264fe407057b5b84d6a2c4c7632cf9b84fe0aeebe8989d1017fb1b5f87b5"
  echo "formal_repetitions=${formal_repetitions}"
  echo "resperf_repetitions=${resperf_repetitions}"
  echo "rates=20000 100000 250000 500000 650000"
  echo "mode_order=balanced-six-permutation-cycle"
  echo "resperf_mode_order=three-way-latin-square"
} >"${result_root}/matrix-metadata.txt"

run_profile dnsperf-radar-observed-20k 20000 5 1
run_profile dnsperf-radar-observed-100k 100000 3 0
run_profile dnsperf-radar-observed-250k 250000 3 0
run_profile dnsperf-radar-observed-500k 500000 3 0
run_profile dnsperf-radar-observed-650k 650000 3 0

health_guard
bpftool net show >"${result_root}/bpf-after.txt"
ip netns list >"${result_root}/netns-after.txt"
for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
  printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done >"${result_root}/kubernetes-after.txt"
grep -q '=active$' "${result_root}/kubernetes-after.txt" && exit 1
echo "matrix_artifacts=${result_root}"
