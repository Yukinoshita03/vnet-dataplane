#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests/udp-fastpath}"
clang_bin="${CLANG:-clang}"
cc_bin="${CC:-gcc}"
cxx_bin="${CXX:-c++}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "UDP fast-path BPF tests require Linux" >&2
  exit 1
fi

mkdir -p "${build_dir}"
multiarch_include="/usr/include/$(${cc_bin} -print-multiarch 2>/dev/null || true)"
bpf_includes=("-I${repo_dir}/src/include" "-I${repo_dir}/include")
if [[ -d "${multiarch_include}" ]]; then
  bpf_includes+=("-I${multiarch_include}")
fi

"${clang_bin}" -target bpf -O2 -g \
  "${bpf_includes[@]}" \
  -c "${repo_dir}/bpf/udp_fastpath.c" \
  -o "${build_dir}/udp_fastpath.bpf.o"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
  read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
else
  libbpf_flags=(-lbpf -lelf -lz)
fi

"${cc_bin}" -std=c11 -O2 -g -Wall -Wextra -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/tests/udp_fastpath_xdp_test.c" \
  -o "${build_dir}/udp_fastpath_xdp_test" \
  "${libbpf_flags[@]}"

"${cxx_bin}" -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  -I"${repo_dir}/src/include" \
  "${repo_dir}/src/udp_fastpath_policy.cpp" \
  "${repo_dir}/src/udp_fastpath.cpp" \
  -o "${build_dir}/udp_fastpath" \
  "${libbpf_flags[@]}"

policy_dir="$(mktemp -d /tmp/udp-fastpath-policy-test.XXXXXX)"
cleanup() {
  rm -rf "${policy_dir}"
}
trap cleanup EXIT

printf '%s\n' \
  'lo 192.0.2.53 9000 70696e67 706f6e672d6f6b 30' \
  >"${policy_dir}/valid.conf"
"${build_dir}/udp_fastpath" \
  --policy-file "${policy_dir}/valid.conf" --validate-only \
  | grep -q 'UDP policy valid entries=1'

printf '%s\n%s\n' \
  'lo 192.0.2.53 9000 70696e67 706f6e672d6f6b 30' \
  'lo 192.0.2.53 9000 70696e67 6f74686572 30' \
  >"${policy_dir}/duplicate.conf"
if "${build_dir}/udp_fastpath" \
  --policy-file "${policy_dir}/duplicate.conf" --validate-only \
  >"${policy_dir}/duplicate.out" 2>&1; then
  echo "Duplicate UDP cache key unexpectedly passed validation" >&2
  exit 1
fi
grep -q 'duplicate UDP cache key' "${policy_dir}/duplicate.out"

python3 - <<'PY' >"${policy_dir}/request-too-large.conf"
print("lo 192.0.2.53 9000 " + "00" * 65 + " 00 30")
PY
if "${build_dir}/udp_fastpath" \
  --policy-file "${policy_dir}/request-too-large.conf" --validate-only \
  >"${policy_dir}/request-too-large.out" 2>&1; then
  echo "Oversized UDP request unexpectedly passed validation" >&2
  exit 1
fi
grep -q 'invalid or oversized UDP hex payload' \
  "${policy_dir}/request-too-large.out"

python3 - <<'PY' >"${policy_dir}/response-too-large.conf"
print("lo 192.0.2.53 9000 00 " + "00" * 65 + " 30")
PY
if "${build_dir}/udp_fastpath" \
  --policy-file "${policy_dir}/response-too-large.conf" --validate-only \
  >"${policy_dir}/response-too-large.out" 2>&1; then
  echo "Oversized UDP response unexpectedly passed validation" >&2
  exit 1
fi
grep -q 'invalid or oversized UDP hex payload' \
  "${policy_dir}/response-too-large.out"
echo "UDP policy parser tests passed"

if (( EUID == 0 )); then
  "${build_dir}/udp_fastpath_xdp_test" "${build_dir}/udp_fastpath.bpf.o"
else
  sudo -- "${build_dir}/udp_fastpath_xdp_test" \
    "${build_dir}/udp_fastpath.bpf.o"
fi
