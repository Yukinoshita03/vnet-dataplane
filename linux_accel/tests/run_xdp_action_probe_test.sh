#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests/xdp-action-probe}"
clang_bin="${CLANG:-clang}"
cc_bin="${CC:-cc}"
bpf_object="${build_dir}/xdp_action_probe.bpf.o"
test_binary="${build_dir}/xdp_action_probe_test"
loader_binary="${build_dir}/xdp_action_probe_loader"
sender_binary="${build_dir}/xdp_action_probe_sender"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "XDP action probe tests require Linux; use a local VM/container" >&2
  exit 1
fi

need_cmd "${clang_bin}"
need_cmd "${cc_bin}"
mkdir -p "${build_dir}"

multiarch_include="/usr/include/$(${cc_bin} -print-multiarch 2>/dev/null || true)"
bpf_includes=("-I${repo_dir}/src/include")
if [[ -d "${multiarch_include}" ]]; then
  bpf_includes+=("-I${multiarch_include}")
fi

"${clang_bin}" -target bpf -O2 -g -Wall -Werror \
  "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/xdp_action_probe.c" \
  -o "${bpf_object}"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
  read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
else
  libbpf_flags=(-lbpf -lelf -lz)
fi

common_c_flags=(-std=c11 -O2 -g -Wall -Wextra -Werror \
  "-I${repo_dir}/src/include")

"${cc_bin}" "${common_c_flags[@]}" \
  "${repo_dir}/tests/xdp_action_probe_test.c" \
  -o "${test_binary}" "${libbpf_flags[@]}"

"${cc_bin}" "${common_c_flags[@]}" \
  "${repo_dir}/tests/xdp_action_probe_loader.c" \
  -o "${loader_binary}" "${libbpf_flags[@]}"

"${cc_bin}" "${common_c_flags[@]}" \
  "${repo_dir}/tests/xdp_action_probe_sender.c" \
  -o "${sender_binary}"

echo "Built ${bpf_object}"
echo "Built ${test_binary}"
echo "Built ${loader_binary}"
echo "Built ${sender_binary}"

"${loader_binary}" --help >/dev/null
"${sender_binary}" --help >/dev/null

if [[ "${BUILD_ONLY:-0}" == "1" ]]; then
  exit 0
fi

if (( EUID == 0 )); then
  exec "${test_binary}" "${bpf_object}"
fi

need_cmd sudo
exec sudo -- "${test_binary}" "${bpf_object}"
