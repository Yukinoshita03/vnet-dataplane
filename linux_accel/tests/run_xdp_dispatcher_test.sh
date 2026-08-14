#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests/xdp-dispatcher}"
clang_bin="${CLANG:-clang}"
cc_bin="${CC:-cc}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "XDP dispatcher BPF tests require Linux; run this script in the Linux VM" >&2
  exit 1
fi

need_cmd "${clang_bin}"
need_cmd "${cc_bin}"
mkdir -p "${build_dir}"

multiarch_include="/usr/include/$(${cc_bin} -print-multiarch 2>/dev/null || true)"
bpf_includes=("-I${repo_dir}/src/include" "-I${repo_dir}/include")
if [[ -d "${multiarch_include}" ]]; then
  bpf_includes+=("-I${multiarch_include}")
fi

"${clang_bin}" -target bpf -O2 -g "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/dns_xdp_monitor.c" \
  -o "${build_dir}/dns_xdp_monitor.bpf.o"
"${clang_bin}" -target bpf -O2 -g "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/udp_fastpath.c" \
  -o "${build_dir}/udp_fastpath.bpf.o"
"${clang_bin}" -target bpf -O2 -g "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/xdp_dispatcher.c" \
  -o "${build_dir}/xdp_dispatcher.bpf.o"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
  read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
else
  libbpf_flags=(-lbpf -lelf -lz)
fi

"${cc_bin}" -std=c11 -O2 -g -Wall -Wextra -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/tests/xdp_dispatcher_prog_test.c" \
  -o "${build_dir}/xdp_dispatcher_prog_test" \
  "${libbpf_flags[@]}"

if (( EUID == 0 )); then
  exec "${build_dir}/xdp_dispatcher_prog_test" \
    "${build_dir}/dns_xdp_monitor.bpf.o" \
    "${build_dir}/udp_fastpath.bpf.o" \
    "${build_dir}/xdp_dispatcher.bpf.o"
fi

need_cmd sudo
exec sudo -- "${build_dir}/xdp_dispatcher_prog_test" \
  "${build_dir}/dns_xdp_monitor.bpf.o" \
  "${build_dir}/udp_fastpath.bpf.o" \
  "${build_dir}/xdp_dispatcher.bpf.o"
