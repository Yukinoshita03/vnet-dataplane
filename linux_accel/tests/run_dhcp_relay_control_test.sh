#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests/dhcp-relay-control}"
cxx_bin="${CXX:-c++}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "DHCP relay control tests require Linux interfaces" >&2
  exit 1
fi
command -v "${cxx_bin}" >/dev/null 2>&1 || {
  echo "missing command: ${cxx_bin}" >&2
  exit 1
}
mkdir -p "${build_dir}"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
  read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
else
  libbpf_flags=(-lbpf -lelf -lz)
fi

"${cxx_bin}" -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/tests/dhcp_relay_control_test.cpp" \
  "${repo_dir}/src/dhcp_relay_control.cpp" \
  -o "${build_dir}/dhcp_relay_control_test" \
  "${libbpf_flags[@]}"

"${build_dir}/dhcp_relay_control_test"
