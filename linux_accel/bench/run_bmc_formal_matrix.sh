#!/usr/bin/env bash
set -Eeuo pipefail

release_root="${RELEASE_ROOT:-/opt/competitor-bench/releases/competitor-preflight-20260813-173626}"
bmc_dir="${BMC_DIR:-${release_root}/bmc-modern-v10}"
linux_dir="${LINUX_DIR:-${release_root}/linux-accel-bmc-target-v8}"
benchmark="${BENCHMARK:-${linux_dir}/bench/bmc_paper_target_competitor_bench.sh}"
run_id="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
result_root="${RESULT_ROOT:-/opt/competitor-bench/results/competitor-preflight-20260813-173626/bmc-formal-matrix-${run_id}}"
repetitions="${REPETITIONS:-6}"
threads="${THREADS:-8}"
requests_per_thread="${REQUESTS_PER_THREAD:-100000}"

if (( EUID != 0 )); then
  echo "run as root" >&2
  exit 1
fi
test -x "${benchmark}"
test ! -e "${result_root}"
mkdir -p "${result_root}"

kubernetes_guard()
{
  local unit
  for unit in kubelet containerd kubernetes-haproxy k3s rke2-server rke2-agent; do
    if [[ "$(systemctl is-active "${unit}" 2>/dev/null || true)" == active ]]; then
      echo "Kubernetes unit unexpectedly active: ${unit}" >&2
      exit 1
    fi
  done
}

run_profile()
{
  local name="$1"
  shift
  kubernetes_guard
  env RELEASE_ROOT="${release_root}" BMC_DIR="${bmc_dir}" \
    LINUX_DIR="${linux_dir}" \
    OUT_DIR="${result_root}/${name}" REPETITIONS="${repetitions}" \
    THREADS="${threads}" REQUESTS_PER_THREAD="${requests_per_thread}" \
    "$@" "${benchmark}"
  kubernetes_guard
}

run_profile bmc-paper-zipf-scaled \
  WORKLOAD_PROFILE=BMC-PAPER-TARGET-scaled-4to1-keyspace \
  SOURCE_PROFILE=BMC-NSDI21-Table3-parameters \
  DISTRIBUTION=zipf ZIPF=0.99 POPULATION=16384 HOT_KEYS=4096 \
  CACHE_ENTRIES=4096 PATH_PROFILE=mixed

run_profile same-slot-pressure \
  WORKLOAD_PROFILE=same-nominal-slot-pressure \
  SOURCE_PROFILE=BMC-NSDI21-Zipf-0.99-synthetic-capacity-stress \
  DISTRIBUTION=zipf ZIPF=0.99 POPULATION=65536 HOT_KEYS=4096 \
  CACHE_ENTRIES=4096 PATH_PROFILE=mixed

run_profile all-hot-hit \
  WORKLOAD_PROFILE=all-hot-hit-control \
  SOURCE_PROFILE=mechanism-control \
  DISTRIBUTION=zipf ZIPF=0.99 POPULATION=4096 HOT_KEYS=4096 \
  CACHE_ENTRIES=4096 PATH_PROFILE=all-hit

run_profile all-backend-miss \
  WORKLOAD_PROFILE=all-backend-miss-control \
  SOURCE_PROFILE=mechanism-control \
  DISTRIBUTION=zipf ZIPF=0.99 POPULATION=4096 HOT_KEYS=4096 \
  CACHE_ENTRIES=4096 PATH_PROFILE=all-miss

# Atikoglu et al. report the ETC coarse locality constraint as roughly half
# the distinct keys carrying 99% of requests and the other half carrying 1%.
# 60,000 keys and 3,000,000 requests make the cold half appear exactly once.
run_profile facebook-etc-coarse-locality \
  WORKLOAD_PROFILE=FB-ETC-COARSE-LOCALITY-exact-scale \
  SOURCE_PROFILE=Atikoglu-SIGMETRICS12-ETC-coarse-locality \
  DISTRIBUTION=facebook-etc-coarse POPULATION=60000 HOT_KEYS=30000 \
  CACHE_ENTRIES=4096 PATH_PROFILE=mixed REQUESTS_PER_THREAD=375000

{
  echo "matrix_run_id=${run_id}"
  echo "result_root=${result_root}"
  echo "repetitions=${repetitions}"
  echo "default_threads=${threads}"
  echo "default_requests_per_thread=${requests_per_thread}"
  echo "facebook_requests_per_thread=375000"
  echo "benchmark=${benchmark}"
  echo "bmc_dir=${bmc_dir}"
  echo "linux_dir=${linux_dir}"
  uname -a
  lscpu
} >"${result_root}/matrix-metadata.txt"

kubernetes_guard
bpftool net show >"${result_root}/bpf-after.txt"
ip netns list >"${result_root}/netns-after.txt"
if grep -Eq '(generic|native|offload) id|clsact|bmc-[cs]-' \
    "${result_root}/bpf-after.txt" "${result_root}/netns-after.txt"; then
  echo "benchmark cleanup invariant failed" >&2
  exit 1
fi

echo "matrix_artifacts=${result_root}"
