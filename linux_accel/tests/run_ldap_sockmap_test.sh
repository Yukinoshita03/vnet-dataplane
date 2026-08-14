#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests/ldap-sockmap}"
clang_bin="${CLANG:-clang}"
cc_bin="${CC:-gcc}"
cxx_bin="${CXX:-c++}"
threads="${LDAP_THREADS:-2}"
requests="${LDAP_REQUESTS:-500}"
warmup="${LDAP_WARMUP:-20}"
response_bytes="${LDAP_RESPONSE_BYTES:-0}"
pipeline="${LDAP_PIPELINE:-1}"
tls_smoke="${LDAP_TLS_SMOKE:-1}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "LDAP sockmap tests require Linux" >&2
  exit 1
fi
if (( EUID != 0 )); then
  echo "Run LDAP sockmap integration tests as root" >&2
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
  -c "${repo_dir}/bpf/ldap_sockmap.c" \
  -o "${build_dir}/ldap_sockmap.bpf.o"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
  read -r -a libbpf_flags <<< "$(pkg-config --cflags --libs libbpf)"
else
  libbpf_flags=(-lbpf -lelf -lz)
fi

"${cxx_bin}" -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  -pthread -I"${repo_dir}/src/include" \
  "${repo_dir}/src/ldap_sockmap_proxy.cpp" \
  -o "${build_dir}/ldap_sockmap_proxy" \
  "${libbpf_flags[@]}"

"${cxx_bin}" -std=c++17 -O2 -g -Wall -Wextra -Wpedantic -Werror \
  -pthread "${repo_dir}/bench/ldap_bench.cpp" \
  -o "${build_dir}/ldap_bench"

run_dir="$(mktemp -d /tmp/ldap-sockmap-test.XXXXXX)"
# Keep listener ports below the default Linux ephemeral range (32768-60999).
# Otherwise a proxy-to-backend connection can transiently consume the port that
# the next test phase is about to bind.
base_port=$((20000 + (($$ % 500) * 8)))
backend_port="${base_port}"
userspace_port=$((base_port + 1))
splice_port=$((base_port + 2))
sockmap_port=$((base_port + 3))
backend_pid=""
proxy_pid=""

cleanup() {
  if [[ -n "${proxy_pid}" ]]; then
    kill -TERM "${proxy_pid}" >/dev/null 2>&1 || true
    wait "${proxy_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${backend_pid}" ]]; then
    kill -TERM "${backend_pid}" >/dev/null 2>&1 || true
    wait "${backend_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

response_args=()
if (( response_bytes > 0 )); then
  response_args=(--response-bytes "${response_bytes}")
fi

wait_port() {
  local port="$1"
  for _ in $(seq 1 50); do
    if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

"${build_dir}/ldap_bench" --server "127.0.0.1:${backend_port}" \
  "${response_args[@]}" \
  >"${run_dir}/backend.log" 2>&1 &
backend_pid=$!
wait_port "${backend_port}"

"${build_dir}/ldap_bench" --client "127.0.0.1:${backend_port}" \
  --threads "${threads}" --requests "${requests}" --warmup "${warmup}" \
  --pipeline "${pipeline}" \
  "${response_args[@]}" \
  | tee "${run_dir}/direct.log"
grep -q 'failed=0' "${run_dir}/direct.log"

"${build_dir}/ldap_sockmap_proxy" \
  --listen "127.0.0.1:${userspace_port}" \
  --backend "127.0.0.1:${backend_port}" --mode userspace \
  >"${run_dir}/userspace-proxy.log" 2>&1 &
proxy_pid=$!
wait_port "${userspace_port}"
"${build_dir}/ldap_bench" --client "127.0.0.1:${userspace_port}" \
  --threads "${threads}" --requests "${requests}" --warmup "${warmup}" \
  --pipeline "${pipeline}" \
  "${response_args[@]}" \
  | tee "${run_dir}/userspace-client.log"
grep -q 'failed=0' "${run_dir}/userspace-client.log"
kill -TERM "${proxy_pid}"
wait "${proxy_pid}"
proxy_pid=""

"${build_dir}/ldap_sockmap_proxy" \
  --listen "127.0.0.1:${splice_port}" \
  --backend "127.0.0.1:${backend_port}" --mode splice \
  >"${run_dir}/splice-proxy.log" 2>&1 &
proxy_pid=$!
wait_port "${splice_port}"
"${build_dir}/ldap_bench" --client "127.0.0.1:${splice_port}" \
  --threads "${threads}" --requests "${requests}" --warmup "${warmup}" \
  --pipeline "${pipeline}" \
  "${response_args[@]}" \
  | tee "${run_dir}/splice-client.log"
grep -q 'failed=0' "${run_dir}/splice-client.log"
kill -TERM "${proxy_pid}"
wait "${proxy_pid}"
proxy_pid=""

"${build_dir}/ldap_sockmap_proxy" \
  --listen "127.0.0.1:${sockmap_port}" \
  --backend "127.0.0.1:${backend_port}" --mode sockmap \
  --bpf-object "${build_dir}/ldap_sockmap.bpf.o" \
  >"${run_dir}/sockmap-proxy.log" 2>&1 &
proxy_pid=$!
wait_port "${sockmap_port}"
"${build_dir}/ldap_bench" --client "127.0.0.1:${sockmap_port}" \
  --threads "${threads}" --requests "${requests}" --warmup "${warmup}" \
  --pipeline "${pipeline}" \
  "${response_args[@]}" \
  | tee "${run_dir}/sockmap-client.log"
grep -q 'failed=0' "${run_dir}/sockmap-client.log"
kill -TERM "${proxy_pid}"
wait "${proxy_pid}"
proxy_pid=""

grep -Eq 'sockmap_pairs=[1-9][0-9]*' "${run_dir}/sockmap-proxy.log"
grep -Eq 'fallback_bytes=0($| )' "${run_dir}/sockmap-proxy.log"
grep -Eq 'redirect_fail=0($| )' "${run_dir}/sockmap-proxy.log"
grep -Eq 'relay_error=0($| )' "${run_dir}/sockmap-proxy.log"
grep -Eq 'splice_bytes=[1-9][0-9]*' "${run_dir}/splice-proxy.log"
grep -Eq 'relay_error=0($| )' "${run_dir}/splice-proxy.log"

# A dead backend must fail one worker without hanging proxy shutdown.
failure_proxy_port=$((base_port + 6))
failure_backend_port=$((base_port + 7))
"${build_dir}/ldap_sockmap_proxy" \
  --listen "127.0.0.1:${failure_proxy_port}" \
  --backend "127.0.0.1:${failure_backend_port}" --mode userspace \
  --connect-timeout-ms 200 \
  >"${run_dir}/connect-failure-proxy.log" 2>&1 &
proxy_pid=$!
wait_port "${failure_proxy_port}"
timeout 2 bash -c \
  "exec 3<>/dev/tcp/127.0.0.1/${failure_proxy_port}; read -r -t 1 <&3 || true"
sleep 0.1
kill -TERM "${proxy_pid}"
wait "${proxy_pid}" || true
proxy_pid=""
grep -Eq 'connect_error=[1-9][0-9]*' \
  "${run_dir}/connect-failure-proxy.log"
grep -Eq 'relay_error=0($| )' "${run_dir}/connect-failure-proxy.log"

if (( tls_smoke != 0 )); then
  command -v openssl >/dev/null
  command -v timeout >/dev/null

  kill -TERM "${backend_pid}"
  wait "${backend_pid}"
  backend_pid=""

  tls_backend_port=$((base_port + 4))
  tls_proxy_port=$((base_port + 5))
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -subj /CN=localhost -days 1 \
    -keyout "${run_dir}/ldaps.key" -out "${run_dir}/ldaps.crt" \
    >"${run_dir}/ldaps-cert.log" 2>&1
  openssl s_server -accept "127.0.0.1:${tls_backend_port}" \
    -cert "${run_dir}/ldaps.crt" -key "${run_dir}/ldaps.key" \
    -www -quiet >"${run_dir}/ldaps-server.log" 2>&1 &
  backend_pid=$!
  wait_port "${tls_backend_port}"

  "${build_dir}/ldap_sockmap_proxy" \
    --listen "127.0.0.1:${tls_proxy_port}" \
    --backend "127.0.0.1:${tls_backend_port}" --mode sockmap \
    --bpf-object "${build_dir}/ldap_sockmap.bpf.o" \
    >"${run_dir}/ldaps-proxy.log" 2>&1 &
  proxy_pid=$!
  wait_port "${tls_proxy_port}"
  printf 'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n' | \
    timeout 10 openssl s_client -quiet \
      -connect "127.0.0.1:${tls_proxy_port}" -servername localhost \
      -CAfile "${run_dir}/ldaps.crt" -verify_return_error \
      >"${run_dir}/ldaps-client.log" 2>"${run_dir}/ldaps-client.err"
  grep -q '^HTTP/1.0 200 ok' "${run_dir}/ldaps-client.log"

  kill -TERM "${proxy_pid}"
  wait "${proxy_pid}"
  proxy_pid=""
  kill -TERM "${backend_pid}"
  wait "${backend_pid}" || true
  backend_pid=""
  grep -Eq 'sockmap_pairs=[1-9][0-9]*' "${run_dir}/ldaps-proxy.log"
  grep -Eq 'fallback_bytes=0($| )' "${run_dir}/ldaps-proxy.log"
  grep -Eq 'redirect_fail=0($| )' "${run_dir}/ldaps-proxy.log"
  grep -Eq 'relay_error=0($| )' "${run_dir}/ldaps-proxy.log"
  echo "LDAPS opaque TLS transport smoke test passed"
fi

echo "LDAP sockmap integration tests passed"
echo "logs=${run_dir}"
