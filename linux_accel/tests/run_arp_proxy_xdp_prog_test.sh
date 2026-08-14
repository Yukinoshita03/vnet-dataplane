#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests/arp-proxy}"
clang_bin="${CLANG:-clang}"
cc_bin="${CC:-gcc}"
cxx_bin="${CXX:-g++}"
multiarch_compiler="${GCC:-gcc}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ARP proxy BPF tests require Linux; run this script in the Linux VM" >&2
  exit 1
fi

need_cmd "${clang_bin}"
need_cmd "${cc_bin}"
need_cmd "${cxx_bin}"
need_cmd "${multiarch_compiler}"
mkdir -p "${build_dir}"

multiarch_include="/usr/include/$(${multiarch_compiler} -print-multiarch 2>/dev/null || true)"
bpf_includes=("-I${repo_dir}/src/include" "-I${repo_dir}/include")
if [[ -d "${multiarch_include}" ]]; then
  bpf_includes+=("-I${multiarch_include}")
fi

"${clang_bin}" -target bpf -O2 -g \
  "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/dns_xdp_monitor.c" \
  -o "${build_dir}/dns_xdp_monitor.bpf.o"

"${clang_bin}" -target bpf -O2 -g \
  "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/dns_client_cache.c" \
  -o "${build_dir}/dns_client_cache.bpf.o"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
  read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
else
  libbpf_flags=(-lbpf -lelf -lz)
fi

"${cc_bin}" -std=c11 -O2 -g -Wall -Wextra -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/tests/arp_proxy_xdp_prog_test.c" \
  -o "${build_dir}/arp_proxy_xdp_prog_test" \
  "${libbpf_flags[@]}"

"${cxx_bin}" -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/tests/arp_proxy_control_test.cpp" \
  "${repo_dir}/src/arp_proxy_control.cpp" \
  -o "${build_dir}/arp_proxy_control_test" \
  "${libbpf_flags[@]}"

echo "Built ${build_dir}/dns_xdp_monitor.bpf.o"
echo "Built ${build_dir}/dns_client_cache.bpf.o"
echo "Built ${build_dir}/arp_proxy_xdp_prog_test"
echo "Built ${build_dir}/arp_proxy_control_test"

if (( EUID == 0 )); then
  "${build_dir}/arp_proxy_xdp_prog_test" \
    "${build_dir}/dns_xdp_monitor.bpf.o" dns_xdp_monitor
  "${build_dir}/arp_proxy_control_test" \
    "${build_dir}/dns_xdp_monitor.bpf.o"
  "${build_dir}/arp_proxy_xdp_prog_test" \
    "${build_dir}/dns_client_cache.bpf.o" dns_client_cache_xdp
else
  need_cmd sudo
  sudo -- "${build_dir}/arp_proxy_xdp_prog_test" \
    "${build_dir}/dns_xdp_monitor.bpf.o" dns_xdp_monitor
  sudo -- "${build_dir}/arp_proxy_control_test" \
    "${build_dir}/dns_xdp_monitor.bpf.o"
  sudo -- "${build_dir}/arp_proxy_xdp_prog_test" \
    "${build_dir}/dns_client_cache.bpf.o" dns_client_cache_xdp
fi
