#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

mkdir -p "${BUILD_DIR}"

command -v clang >/dev/null
command -v c++ >/dev/null
command -v tc >/dev/null
command -v pkg-config >/dev/null

if ! pkg-config --exists libcurl; then
  echo "libcurl development files are required (pkg-config libcurl)" >&2
  exit 1
fi

read -r -a CURL_FLAGS <<< "$(pkg-config --cflags --libs libcurl)"

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
  -c "${ROOT_DIR}/bpf/dns_client_cache.c" \
  -o "${BUILD_DIR}/dns_client_cache.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/grpc_monitor.c" \
  -o "${BUILD_DIR}/grpc_monitor.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/udp_fastpath.c" \
  -o "${BUILD_DIR}/udp_fastpath.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/xdp_dispatcher.c" \
  -o "${BUILD_DIR}/xdp_dispatcher.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/ldap_sockmap.c" \
  -o "${BUILD_DIR}/ldap_sockmap.bpf.o"

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/dns_cache_config.cpp" \
  "${ROOT_DIR}/src/udp_fastpath_policy.cpp" \
  "${ROOT_DIR}/src/arp_proxy_control.cpp" \
  "${ROOT_DIR}/src/dhcp_relay_control.cpp" \
  "${ROOT_DIR}/src/interface_feed.cpp" \
  "${ROOT_DIR}/src/policy_reconciler.cpp" \
  "${ROOT_DIR}/src/policy_feed.cpp" \
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
  "${ROOT_DIR}/src/udp_fastpath_policy.cpp" \
  "${ROOT_DIR}/src/udp_fastpath.cpp" \
  -o "${BUILD_DIR}/udp_fastpath" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g -pthread \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/ldap_sockmap_proxy.cpp" \
  -o "${BUILD_DIR}/ldap_sockmap_proxy" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/packet_parser.cpp" \
  "${ROOT_DIR}/src/virt_service_classifier.cpp" \
  -o "${BUILD_DIR}/virt_service_classifier"

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/campus_net_guard.cpp" \
  "${CURL_FLAGS[@]}" \
  -o "${BUILD_DIR}/campus_net_guard"

echo "Built ${BUILD_DIR}/dns_monitor.bpf.o"
echo "Built ${BUILD_DIR}/dns_xdp_monitor.bpf.o"
echo "Built ${BUILD_DIR}/dns_client_cache.bpf.o"
echo "Built ${BUILD_DIR}/grpc_monitor.bpf.o"
echo "Built ${BUILD_DIR}/udp_fastpath.bpf.o"
echo "Built ${BUILD_DIR}/xdp_dispatcher.bpf.o"
echo "Built ${BUILD_DIR}/ldap_sockmap.bpf.o"
echo "Built ${BUILD_DIR}/dns_monitor"
echo "Built ${BUILD_DIR}/grpc_monitor"
echo "Built ${BUILD_DIR}/grpc_fast_cache"
echo "Built ${BUILD_DIR}/cachectl"
echo "Built ${BUILD_DIR}/udp_fastpath"
echo "Built ${BUILD_DIR}/ldap_sockmap_proxy"
echo "Built ${BUILD_DIR}/virt_service_classifier"
echo "Built ${BUILD_DIR}/campus_net_guard"
