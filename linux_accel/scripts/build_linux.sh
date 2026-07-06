#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

mkdir -p "${BUILD_DIR}"

command -v clang >/dev/null
command -v c++ >/dev/null
command -v tc >/dev/null

MULTIARCH_INCLUDE="/usr/include/$(gcc -print-multiarch 2>/dev/null || true)"
BPF_INCLUDES=("-I${ROOT_DIR}/src/include" "-I${ROOT_DIR}/include")
if [[ -d "${MULTIARCH_INCLUDE}" ]]; then
  BPF_INCLUDES+=("-I${MULTIARCH_INCLUDE}")
fi

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/dns_monitor.c" \
  -o "${BUILD_DIR}/dns_monitor.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/dns_xdp_monitor.c" \
  -o "${BUILD_DIR}/dns_xdp_monitor.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/grpc_monitor.c" \
  -o "${BUILD_DIR}/grpc_monitor.bpf.o"

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/dns_cache_config.cpp" \
  "${ROOT_DIR}/src/dns_monitor.cpp" \
  "${ROOT_DIR}/src/dns_monitor_args.cpp" \
  "${ROOT_DIR}/src/dns_monitor_metrics.cpp" \
  -o "${BUILD_DIR}/dns_monitor" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/grpc_monitor.cpp" \
  -o "${BUILD_DIR}/grpc_monitor" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/grpc_fast_cache.cpp" \
  "${ROOT_DIR}/src/cache_policy.cpp" \
  "${ROOT_DIR}/src/dns_cache_config.cpp" \
  -o "${BUILD_DIR}/grpc_fast_cache" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/cachectl.cpp" \
  "${ROOT_DIR}/src/cache_policy.cpp" \
  "${ROOT_DIR}/src/dns_cache_config.cpp" \
  -o "${BUILD_DIR}/cachectl" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/packet_parser.cpp" \
  "${ROOT_DIR}/src/virt_service_classifier.cpp" \
  -o "${BUILD_DIR}/virt_service_classifier"

echo "Built ${BUILD_DIR}/dns_monitor.bpf.o"
echo "Built ${BUILD_DIR}/dns_xdp_monitor.bpf.o"
echo "Built ${BUILD_DIR}/grpc_monitor.bpf.o"
echo "Built ${BUILD_DIR}/dns_monitor"
echo "Built ${BUILD_DIR}/grpc_monitor"
echo "Built ${BUILD_DIR}/grpc_fast_cache"
echo "Built ${BUILD_DIR}/cachectl"
echo "Built ${BUILD_DIR}/virt_service_classifier"
