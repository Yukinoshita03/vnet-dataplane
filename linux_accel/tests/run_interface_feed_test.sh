#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests/interface-feed}"
cxx_bin="${CXX:-c++}"

command -v "${cxx_bin}" >/dev/null 2>&1 || {
  echo "missing command: ${cxx_bin}" >&2
  exit 1
}
mkdir -p "${build_dir}"

"${cxx_bin}" -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/tests/interface_feed_test.cpp" \
  "${repo_dir}/src/interface_feed.cpp" \
  -o "${build_dir}/interface_feed_test"

"${build_dir}/interface_feed_test"
