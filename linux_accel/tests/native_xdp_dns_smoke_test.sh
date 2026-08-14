#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${message}: expected ${expected}, got ${actual}"
}

unset MIN_DNS_SUCCESSES
NATIVE_XDP_DNS_SMOKE_SOURCE_ONLY=1
# shellcheck source=../bench/native_xdp_dns_smoke.sh
source "${repo_dir}/bench/native_xdp_dns_smoke.sh"
unset NATIVE_XDP_DNS_SMOKE_SOURCE_ONLY

assert_equal 256 "${tx_ring_entries}" "driver TX ring contract"
assert_equal 512 "${min_dns_successes}" "default completion stress count"
validate_completion_requirement 512
if validate_completion_requirement 256 2>/dev/null; then
  fail "a success count that does not cross the TX ring was accepted"
fi

cat > "${work_dir}/dns-monitor.log" <<'EOF'
xdp_program_id=42
dns_metrics dev=enp3s0 role=server qps=0 cache_hit=300 cache_tx=300 alerts=none
dns_metrics dev=enp3s0 role=server qps=0 cache_hit=213 cache_tx=213 alerts=none
dns_metrics dev=enp3s0 role=server qps=0 cache_hit=0 cache_tx=0 alerts=none
EOF

assert_equal 513 "$(metric_total cache_hit "${work_dir}/dns-monitor.log")" \
  "cache-hit deltas are summed across report windows"
assert_equal 513 "$(metric_total cache_tx "${work_dir}/dns-monitor.log")" \
  "cache-TX deltas survive a final zero window"

cat > "${work_dir}/peer-good.log" <<'EOF'
peer diagnostic output may precede the contract
peer_dns_successes=512
peer_dns_sentinel_after_quiet=1
peer_dns_query_bytes=30
peer_dns_response_bytes=46
peer_ordinary_packet_success=1
EOF

validate_peer_evidence "${work_dir}/peer-good.log" 512
assert_equal 512 "${peer_dns_successes}" "peer bulk success count"
assert_equal 513 "${expected_dns_tx}" "sentinel is additional to bulk traffic"

sed 's/peer_dns_successes=512/peer_dns_successes=511/' \
  "${work_dir}/peer-good.log" > "${work_dir}/peer-short.log"
if validate_peer_evidence "${work_dir}/peer-short.log" 512 2>/dev/null; then
  fail "peer evidence below the ring-crossing minimum was accepted"
fi

sed 's/peer_dns_response_bytes=46/peer_dns_response_bytes=45/' \
  "${work_dir}/peer-good.log" > "${work_dir}/peer-wrong-tail.log"
if validate_peer_evidence "${work_dir}/peer-wrong-tail.log" 512 2>/dev/null; then
  fail "peer evidence without a 16-byte response growth was accepted"
fi

cp "${work_dir}/peer-good.log" "${work_dir}/peer-duplicate.log"
printf '%s\n' 'peer_dns_sentinel_after_quiet=1' >> \
  "${work_dir}/peer-duplicate.log"
if validate_peer_evidence "${work_dir}/peer-duplicate.log" 512 2>/dev/null; then
  fail "duplicate peer contract fields were accepted"
fi

cat > "${work_dir}/ethtool-before.txt" <<'EOF'
     xdp_pass: 100
     xdp_drop: 4
     xdp_aborted: 2
     xdp_tx: 50
     xdp_tx_full: 1
     xdp_invalid_action: 3
     xdp_tx_errors: 5
     xdp_rx_refill_errors: 6
EOF
cat > "${work_dir}/ethtool-after.txt" <<'EOF'
     xdp_pass: 104
     xdp_drop: 4
     xdp_aborted: 2
     xdp_tx: 563
     xdp_tx_full: 1
     xdp_invalid_action: 3
     xdp_tx_errors: 5
     xdp_rx_refill_errors: 6
EOF

assert_equal 4 "$(ethtool_stat_delta \
  "${work_dir}/ethtool-before.txt" "${work_dir}/ethtool-after.txt" xdp_pass)" \
  "XDP_PASS delta"
assert_equal 513 "$(ethtool_stat_delta \
  "${work_dir}/ethtool-before.txt" "${work_dir}/ethtool-after.txt" xdp_tx)" \
  "XDP_TX delta"
for stat_name in xdp_drop xdp_aborted xdp_tx_full xdp_invalid_action \
  xdp_tx_errors xdp_rx_refill_errors; do
  assert_equal 0 "$(ethtool_stat_delta \
    "${work_dir}/ethtool-before.txt" "${work_dir}/ethtool-after.txt" \
    "${stat_name}")" "${stat_name} stays unchanged"
done

printf '%s\n' 1000 > "${work_dir}/tx-packets-before.txt"
printf '%s\n' 1530 > "${work_dir}/tx-packets-after.txt"
assert_equal 530 "$(file_counter_delta \
  "${work_dir}/tx-packets-before.txt" \
  "${work_dir}/tx-packets-after.txt" tx_packets)" \
  "completion-side TX packets"

validate_driver_evidence \
  "${work_dir}/ethtool-before.txt" "${work_dir}/ethtool-after.txt" \
  "${work_dir}/tx-packets-before.txt" \
  "${work_dir}/tx-packets-after.txt" 513
assert_equal 4 "${xdp_pass_delta}" "validated XDP_PASS delta"
assert_equal 513 "${xdp_tx_delta}" "validated XDP_TX delta"
assert_equal 530 "${tx_packets_delta}" "validated completion packet delta"

sed 's/xdp_tx_errors: 5/xdp_tx_errors: 6/' \
  "${work_dir}/ethtool-after.txt" > "${work_dir}/ethtool-error.txt"
if validate_driver_evidence \
  "${work_dir}/ethtool-before.txt" "${work_dir}/ethtool-error.txt" \
  "${work_dir}/tx-packets-before.txt" \
  "${work_dir}/tx-packets-after.txt" 513 2>/dev/null; then
  fail "a non-zero XDP TX error delta was accepted"
fi

printf '%s\n' 1512 > "${work_dir}/tx-packets-short.txt"
if validate_driver_evidence \
  "${work_dir}/ethtool-before.txt" "${work_dir}/ethtool-after.txt" \
  "${work_dir}/tx-packets-before.txt" \
  "${work_dir}/tx-packets-short.txt" 513 2>/dev/null; then
  fail "completion-side packet accounting below the peer count was accepted"
fi

sed 's/xdp_tx: 563/xdp_tx: 581/' \
  "${work_dir}/ethtool-after.txt" > "${work_dir}/ethtool-more-tx.txt"
if validate_driver_evidence \
  "${work_dir}/ethtool-before.txt" "${work_dir}/ethtool-more-tx.txt" \
  "${work_dir}/tx-packets-before.txt" \
  "${work_dir}/tx-packets-after.txt" 513 2>/dev/null; then
  fail "submitted XDP_TX frames without completion-side accounting were accepted"
fi

if counter_delta 10 9 backwards-counter >/dev/null 2>&1; then
  fail "a backwards driver counter was accepted"
fi

echo "ok - native XDP DNS smoke evidence helpers"
