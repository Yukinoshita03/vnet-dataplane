#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
upstream_repo="${1:?usage: $0 UPSTREAM_BMC_REPOSITORY OUTPUT_DIRECTORY}"
output_dir="${2:?usage: $0 UPSTREAM_BMC_REPOSITORY OUTPUT_DIRECTORY}"

pinned_commit="2997145508e02c55aa92f63a0009ac2a26800810"
compat_patch="${repo_root}/patches/competitors/0001-bmc-linux7-libbpf16-tap-compat.patch"
expected_common_sha="03fabf2a4f645675c00b9a7d605700eb3a192697aef406ed450dbc1a8d94fe36"
expected_kernel_sha="5ccacdf0ef8cb72658eb9a301eca4830572992b2c38a21c63bf22cd3f360de09"
expected_loader_sha="dc31ed6b8be19663ea1d4c2a28d01b7fa4a65a5e3904562f98f29c4e875abe47"

for command in git tar patch clang g++ pkg-config sha256sum; do
  command -v "${command}" >/dev/null
done
test -d "${upstream_repo}/.git"
test -r "${compat_patch}"
test -r "${repo_root}/bench/bmc_modern_loader.cpp"
test "$(git -C "${upstream_repo}" rev-parse "${pinned_commit}^{commit}")" = "${pinned_commit}"

if [[ -e "${output_dir}" ]] &&
   [[ -n "$(find "${output_dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "output directory must be absent or empty: ${output_dir}" >&2
  exit 2
fi
mkdir -p "${output_dir}"

work_dir="$(mktemp -d)"
cleanup()
{
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

git -C "${upstream_repo}" archive "${pinned_commit}" bmc |
  tar -x -C "${work_dir}"
patch --batch --forward -d "${work_dir}" -p1 <"${compat_patch}"

common_sha="$(sha256sum "${work_dir}/bmc/bmc_common.h" | awk '{print $1}')"
kernel_sha="$(sha256sum "${work_dir}/bmc/bmc_kern.c" | awk '{print $1}')"
loader_sha="$(sha256sum "${repo_root}/bench/bmc_modern_loader.cpp" | awk '{print $1}')"
test "${common_sha}" = "${expected_common_sha}"
test "${kernel_sha}" = "${expected_kernel_sha}"
test "${loader_sha}" = "${expected_loader_sha}"

multiarch="$(gcc -print-multiarch 2>/dev/null || true)"
bpf_includes=(
  -I"${work_dir}/bmc"
  -I/usr/include/bpf
)
if [[ -n "${multiarch}" && -d "/usr/include/${multiarch}" ]]; then
  bpf_includes+=("-I/usr/include/${multiarch}")
fi

clang -O2 -g -target bpf -D__TARGET_ARCH_x86 \
  -DBMC_MAX_KEY_LENGTH=16 \
  -DBMC_MAX_VAL_LENGTH=32 \
  -DBMC_MAX_KEY_IN_MULTIGET=1 \
  -DBMC_CACHE_ENTRY_COUNT=4096 \
  -DBMC_MAX_PACKET_LENGTH=256 \
  -fdebug-prefix-map="${work_dir}"=/usr/src/bmc-cache \
  "${bpf_includes[@]}" \
  -c "${work_dir}/bmc/bmc_kern.c" -o "${output_dir}/bmc_kern.o"

g++ -O2 -g -std=c++20 -Wall -Wextra \
  "${repo_root}/bench/bmc_modern_loader.cpp" \
  -o "${output_dir}/bmc_loader" \
  $(pkg-config --cflags --libs libbpf)

install -m 0644 "${work_dir}/bmc/bmc_common.h" "${output_dir}/bmc_common.h"
install -m 0644 "${work_dir}/bmc/bmc_kern.c" "${output_dir}/bmc_kern.c"
install -m 0644 "${repo_root}/bench/bmc_modern_loader.cpp" \
  "${output_dir}/bmc_modern_loader.cpp"
install -m 0644 "${compat_patch}" "${output_dir}/0001-bmc-linux7-libbpf16-tap-compat.patch"
install -m 0644 "${upstream_repo}/LICENSE" "${output_dir}/LICENSE.bmc-cache"

{
  echo "upstream=Orange-OpenSource/bmc-cache"
  echo "upstream_commit=${pinned_commit}"
  echo "profile_key_bytes=16"
  echo "profile_value_bytes=32"
  echo "profile_multiget=1"
  echo "profile_cache_entries=4096"
  echo "benchmark_hot_keys=1024"
  echo "profile_max_packet_bytes=256"
  echo "tap_tailroom_bytes=48"
  echo "clang=$(clang --version | head -1)"
  echo "gxx=$(g++ --version | head -1)"
  echo "libbpf=$(pkg-config --modversion libbpf)"
  uname -a
} >"${output_dir}/BUILD-METADATA.txt"

(
  cd "${output_dir}"
  sha256sum bmc_common.h bmc_kern.c bmc_kern.o bmc_loader \
    bmc_modern_loader.cpp 0001-bmc-linux7-libbpf16-tap-compat.patch \
    LICENSE.bmc-cache BUILD-METADATA.txt >SHA256SUMS
)

echo "built BMC compatibility release at ${output_dir}"
cat "${output_dir}/SHA256SUMS"
