#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests}"
clang_bin="${CLANG:-clang}"
cc_bin="${CC:-gcc}"
bpf_object="${build_dir}/dns_xdp_monitor-dhcp.bpf.o"
test_binary="${build_dir}/dhcp_relay_xdp_prog_test"

need_cmd()
{
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "DHCP BPF_PROG_TEST_RUN requires a Linux kernel" >&2
  exit 1
fi

need_cmd "${clang_bin}"
need_cmd "${cc_bin}"
mkdir -p "${build_dir}"

multiarch_compiler="${GCC:-gcc}"
if ! command -v "${multiarch_compiler}" >/dev/null 2>&1; then
  multiarch_compiler="${cc_bin}"
fi
multiarch_include="/usr/include/$(${multiarch_compiler} -print-multiarch 2>/dev/null || true)"
bpf_includes=("-I${repo_dir}/src/include" "-I${repo_dir}/include")
if [[ -d "${multiarch_include}" ]]; then
  bpf_includes+=("-I${multiarch_include}")
fi

"${clang_bin}" -target bpf -O2 -g \
  "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/dns_xdp_monitor.c" \
  -o "${bpf_object}"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
  read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
else
  libbpf_flags=(-lbpf -lelf -lz)
fi

"${cc_bin}" -std=c11 -O2 -g -Wall -Wextra \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/tests/dhcp_relay_xdp_prog_test.c" \
  -o "${test_binary}" \
  "${libbpf_flags[@]}"

echo "Built ${bpf_object}"
echo "Built ${test_binary}"

if (( EUID == 0 )); then
  exec "${test_binary}" "${bpf_object}"
fi
need_cmd sudo
exec sudo -- "${test_binary}" "${bpf_object}"
