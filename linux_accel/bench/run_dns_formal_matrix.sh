#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${RELEASE_DIR:-/opt/competitor-bench/releases/competitor-preflight-20260813-173626/dns-radar-v10}"
linux_dir="${LINUX_DIR:-${release_dir}/linux-accel}"
xpress_src="${XPRESS_SRC:-${release_dir}/xpress-patched}"
benchmark="${BENCHMARK:-${linux_dir}/bench/radar_dns_xdp_competitor_bench.sh}"
run_id="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
result_root="${RESULT_ROOT:-/opt/competitor-bench/results/competitor-preflight-20260813-173626/dns-formal-matrix-${run_id}}"
formal_repetitions="${FORMAL_REPETITIONS:-6}"
capacity_repetitions="${CAPACITY_REPETITIONS:-3}"

if (( EUID != 0 )); then
  echo "run as root" >&2
  exit 1
fi
test -x "${benchmark}"
test -f "${xpress_src}/src/xdp_dns_kern.c"
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
  local name="$1" repetitions="$2" rate="$3" corpus="$4" lines="$5"
  local source="$6" profile_duration="$7" profile_threads="$8"
  local control_cpu backend_cpu
  if (( profile_threads == 10 )); then
    control_cpu=11
    backend_cpu=10
  else
    control_cpu=6
    backend_cpu=8
  fi
  health_guard
  env XPRESS_SRC="${xpress_src}" XPRESS_COMMIT=312e2a30c7838be0c5b92ab5d302a04a55f5afcd \
    BUILD_DIR="${linux_dir}/build/radar-dns-xdp-competitor" \
    OUT_DIR="${result_root}/${name}" REPETITIONS="${repetitions}" \
    RATE="${rate}" DURATION="${profile_duration}" THREADS="${profile_threads}" \
    BATCH=32 CPU_BASE=0 CONTROL_CPU="${control_cpu}" \
    BACKEND_CPU="${backend_cpu}" TIMEOUT_US=50000 \
    CORPUS_PROFILE="${corpus}" CORPUS_LINES="${lines}" \
    WORKLOAD_PROFILE="${name}" SOURCE_PROFILE="${source}" \
    "${benchmark}"
  health_guard
}

# Low-load, six-order balanced comparisons isolate latency, forwarding
# overhead and backend offload without saturating the Python reference server.
run_profile radar-observed-20k "${formal_repetitions}" 20000 \
  radar-nl-observed 50000 Cloudflare-Radar-NL-observed-marginals 5 6
run_profile radar-a-78.5-hit-20k "${formal_repetitions}" 20000 \
  radar-a-observed 50000 Cloudflare-Radar-cache-marginal-conditioned-on-A 5 6
run_profile all-a-hit-500k "${formal_repetitions}" 500000 \
  a-all-hit 50000 mechanism-control 1 10
run_profile all-a-miss-20k "${formal_repetitions}" 20000 \
  a-all-miss 50000 mechanism-control 5 6
run_profile radar-non-a-forward-20k "${formal_repetitions}" 20000 \
  radar-non-a-observed 43400 Cloudflare-Radar-non-A-QTYPE-renormalized 5 6
run_profile fail-open-shapes-20k "${formal_repetitions}" 20000 \
  fail-open-aaaa-nxdomain-cname 50000 synthetic-forwarding-shape-control 5 6

# Reuse the formal 20k point above, then sweep the observed workload to expose
# each path's loss/capacity knee under the same generator and corpus semantics.
for rate in 100000 250000 500000 650000; do
  run_profile "radar-observed-${rate}" "${capacity_repetitions}" "${rate}" \
    radar-nl-observed 50000 Cloudflare-Radar-NL-observed-marginals 1 10
done

{
  echo "matrix_run_id=${run_id}"
  echo "result_root=${result_root}"
  echo "formal_repetitions=${formal_repetitions}"
  echo "capacity_repetitions=${capacity_repetitions}"
  echo "low_load_shape=6 client sockets, 5 second timed interval"
  echo "high_load_shape=10 client sockets, 1 second timed interval"
  echo "dns_id_safety=high-load requests per socket stay below 65536 per timed interval"
  echo "xpress_commit=312e2a30c7838be0c5b92ab5d302a04a55f5afcd"
  echo "server_xdp_per_packet_telemetry=false"
  uname -a
  lscpu
} >"${result_root}/matrix-metadata.txt"

health_guard
bpftool net show >"${result_root}/bpf-after.txt"
ip netns list >"${result_root}/netns-after.txt"
if grep -Eq 'rdc[0-9]+|rds[0-9]+' "${result_root}/netns-after.txt"; then
  echo "DNS benchmark namespace remains after matrix" >&2
  exit 1
fi

echo "matrix_artifacts=${result_root}"
