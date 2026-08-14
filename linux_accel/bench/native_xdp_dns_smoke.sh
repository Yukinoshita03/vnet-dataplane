#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iface="${IFACE:-}"
expected_driver="${EXPECTED_DRIVER:-r8169}"
domain="${DOMAIN:-example.test}"
answer_ip="${ANSWER_IP:-10.0.0.123}"
ttl="${TTL:-300}"
duration="${DURATION:-60}"
peer_timeout="${PEER_TIMEOUT:-45}"
tx_ring_entries=256
min_dns_successes="${MIN_DNS_SUCCESSES:-512}"
traffic_cmd="${PEER_TRAFFIC_CMD:-}"
allow_disruptive="${ALLOW_DISRUPTIVE:-0}"
allow_management_iface="${ALLOW_MANAGEMENT_IFACE:-0}"
module_file="${MODULE_FILE:-}"
expected_module_sha256="${EXPECTED_MODULE_SHA256:-}"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/native-xdp-dns-smoke/$(date +%Y%m%d-%H%M%S)}"

monitor_pid=""
attached_xdp_id=""

usage() {
  cat <<'EOF'
Usage:
  IFACE=<physical-iface> ALLOW_DISRUPTIVE=1 \
    MODULE_FILE=/path/to/reviewed/r8169_xdp.ko \
    EXPECTED_DRIVER=r8169_xdp \
    EXPECTED_MODULE_SHA256=<sha256> \
    PEER_TRAFFIC_CMD="ssh <peer> '<run the documented peer contract>'" \
    ./bench/native_xdp_dns_smoke.sh

This test attaches the project's real DNS cache program in native/driver XDP
mode. The query must enter the DUT from an external peer; sending to the DUT's
own address locally does not exercise the physical RX path.

Safety controls:
  ALLOW_DISRUPTIVE=1        Required because an experimental driver/XDP path
                            can interrupt networking.
  ALLOW_MANAGEMENT_IFACE=1  Also required when IFACE owns the default route.
  EXPECTED_DRIVER=r8169     Refuses a different active/module driver by
                            default; use r8169_xdp for the coexistence trial.
  MODULE_FILE               Exact reviewed module artifact; this script checks
                            its name, vermagic and SHA-256 but never loads it.
  EXPECTED_MODULE_SHA256    Required hash of MODULE_FILE.
  PEER_TRAFFIC_CMD          Required trusted command. It must run on an
                            external peer, complete MIN_DNS_SUCCESSES successful
                            cache-hit queries, wait, complete one sentinel query,
                            verify an ordinary packet, and print these exact
                            one-per-line fields:
                              peer_dns_successes=<count before sentinel>
                              peer_dns_sentinel_after_quiet=1
                              peer_dns_query_bytes=<DNS query bytes>
                              peer_dns_response_bytes=<DNS response bytes>
                              peer_ordinary_packet_success=1
                            The response/query size difference must be 16.
  MIN_DNS_SUCCESSES=512     Pre-sentinel successes. It must be greater than the
                            driver's 256-entry TX ring so completion/reuse is
                            required. The sentinel is additional.
  PEER_TIMEOUT=45           Maximum seconds for the peer assertion; DURATION
                            must leave at least 10 additional seconds.

Run `sudo -v` interactively before this script. The hardware smoke deliberately
does not accept a password environment variable or put credentials on a command
line.
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

run_sudo() {
  sudo -n "$@"
}

native_xdp_id() {
  local link_details

  if ! link_details="$(ip -details link show dev "${iface}" 2>/dev/null)"; then
    echo "failed to query XDP state for ${iface}" >&2
    return 1
  fi
  awk '
    /prog\/xdp / {
      for (i = 1; i <= NF; i++) {
        if ($i == "id") {
          print $(i + 1)
          exit
        }
      }
    }
  ' <<< "${link_details}"
}

loader_xdp_id() {
  local log_file="$1"

  awk -F= '$1 == "xdp_program_id" { print $2; exit }' "${log_file}"
}

assert_owned_xdp() {
  local phase="$1"
  local current_xdp_id

  current_xdp_id="$(native_xdp_id)"
  if [[ -z "${attached_xdp_id}" ||
        "${current_xdp_id}" != "${attached_xdp_id}" ]]; then
    echo "XDP ownership changed ${phase}: expected ${attached_xdp_id:-none}, found ${current_xdp_id:-none}" >&2
    return 1
  fi
}

metric_total() {
  local name="$1"
  local log_file="$2"

  awk -v key="${name}" '
    $1 == "dns_metrics" {
      for (i = 2; i <= NF; i++) {
        split($i, field, "=")
        if (field[1] == key && field[2] ~ /^[0-9]+$/) {
          total += field[2]
          seen = 1
        }
      }
    }
    END {
      if (!seen)
        exit 1
      printf "%.0f\n", total
    }
  ' "${log_file}"
}

peer_metric_value() {
  local name="$1"
  local log_file="$2"

  awk -F= -v key="${name}" '
    $1 == key && NF == 2 {
      if (seen)
        duplicate = 1
      value = $2
      sub(/\r$/, "", value)
      seen = 1
    }
    END {
      if (!seen || duplicate)
        exit 1
      print value
    }
  ' "${log_file}"
}

ethtool_stat_value() {
  local stat_file="$1"
  local stat_name="$2"

  awk -F: -v key="${stat_name}" '
    {
      name = $1
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (name == key) {
        print value
        exit
      }
    }
  ' "${stat_file}"
}

counter_delta() {
  local before="$1"
  local after="$2"
  local name="$3"

  if [[ ! "${before}" =~ ^[0-9]+$ || ! "${after}" =~ ^[0-9]+$ ]]; then
    echo "missing or invalid counter ${name}: before=${before:-missing} after=${after:-missing}" >&2
    return 1
  fi
  if (( after < before )); then
    echo "counter ${name} moved backwards: before=${before} after=${after}" >&2
    return 1
  fi
  printf '%s\n' "$((after - before))"
}

ethtool_stat_delta() {
  local before_file="$1"
  local after_file="$2"
  local stat_name="$3"
  local before after

  before="$(ethtool_stat_value "${before_file}" "${stat_name}")"
  after="$(ethtool_stat_value "${after_file}" "${stat_name}")"
  counter_delta "${before}" "${after}" "${stat_name}"
}

file_counter_delta() {
  local before_file="$1"
  local after_file="$2"
  local counter_name="$3"
  local before after

  before="$(tr -d '[:space:]' < "${before_file}")"
  after="$(tr -d '[:space:]' < "${after_file}")"
  counter_delta "${before}" "${after}" "${counter_name}"
}

validate_completion_requirement() {
  local required_successes="$1"

  if [[ ! "${required_successes}" =~ ^[1-9][0-9]*$ ]]; then
    echo "MIN_DNS_SUCCESSES must be a positive integer" >&2
    return 1
  fi
  if (( required_successes <= tx_ring_entries )); then
    echo "MIN_DNS_SUCCESSES must exceed the ${tx_ring_entries}-entry TX ring" >&2
    return 1
  fi
}

validate_peer_evidence() {
  local peer_log="$1"
  local required_successes="$2"
  local field

  peer_dns_successes="$(peer_metric_value peer_dns_successes "${peer_log}")" || {
    echo "peer evidence is missing one unique peer_dns_successes field" >&2
    return 1
  }
  peer_dns_sentinel="$(peer_metric_value peer_dns_sentinel_after_quiet "${peer_log}")" || {
    echo "peer evidence is missing one unique peer_dns_sentinel_after_quiet field" >&2
    return 1
  }
  peer_dns_query_bytes="$(peer_metric_value peer_dns_query_bytes "${peer_log}")" || {
    echo "peer evidence is missing one unique peer_dns_query_bytes field" >&2
    return 1
  }
  peer_dns_response_bytes="$(peer_metric_value peer_dns_response_bytes "${peer_log}")" || {
    echo "peer evidence is missing one unique peer_dns_response_bytes field" >&2
    return 1
  }
  peer_ordinary_packet_success="$(peer_metric_value peer_ordinary_packet_success "${peer_log}")" || {
    echo "peer evidence is missing one unique peer_ordinary_packet_success field" >&2
    return 1
  }

  for field in peer_dns_successes peer_dns_sentinel peer_dns_query_bytes \
    peer_dns_response_bytes peer_ordinary_packet_success; do
    if [[ ! "${!field}" =~ ^[0-9]+$ ]]; then
      echo "peer evidence field ${field} is not an unsigned integer: ${!field}" >&2
      return 1
    fi
  done
  if (( peer_dns_successes < required_successes )); then
    echo "external peer reported only ${peer_dns_successes} pre-sentinel DNS successes; required ${required_successes}" >&2
    return 1
  fi
  if (( peer_dns_sentinel != 1 )); then
    echo "external peer did not confirm exactly one post-quiet sentinel" >&2
    return 1
  fi
  if (( peer_ordinary_packet_success != 1 )); then
    echo "external peer did not confirm ordinary-packet success" >&2
    return 1
  fi
  if (( peer_dns_response_bytes != peer_dns_query_bytes + 16 )); then
    echo "external peer DNS size evidence does not show adjust_tail(+16): query=${peer_dns_query_bytes} response=${peer_dns_response_bytes}" >&2
    return 1
  fi

  expected_dns_tx=$((peer_dns_successes + peer_dns_sentinel))
}

validate_driver_evidence() {
  local before_stats="$1"
  local after_stats="$2"
  local before_tx_packets="$3"
  local after_tx_packets="$4"
  local required_tx="$5"
  local stat_name stat_delta

  xdp_pass_delta="$(ethtool_stat_delta \
    "${before_stats}" "${after_stats}" xdp_pass)" || return 1
  xdp_tx_delta="$(ethtool_stat_delta \
    "${before_stats}" "${after_stats}" xdp_tx)" || return 1
  tx_packets_delta="$(file_counter_delta \
    "${before_tx_packets}" "${after_tx_packets}" tx_packets)" || return 1

  if (( xdp_pass_delta < 1 )); then
    echo "driver did not observe ordinary XDP_PASS traffic" >&2
    return 1
  fi
  if (( xdp_tx_delta < required_tx )); then
    echo "driver submitted fewer XDP_TX frames than the peer confirmed: expected=${required_tx} xdp_tx_delta=${xdp_tx_delta}" >&2
    return 1
  fi
  if (( tx_packets_delta < required_tx )); then
    echo "completion-side TX packet accounting did not cover the peer-confirmed DNS replies: expected=${required_tx} tx_packets_delta=${tx_packets_delta}" >&2
    return 1
  fi
  if (( tx_packets_delta < xdp_tx_delta )); then
    echo "completion-side TX packet accounting did not cover every submitted XDP_TX frame: xdp_tx_delta=${xdp_tx_delta} tx_packets_delta=${tx_packets_delta}" >&2
    return 1
  fi

  for stat_name in xdp_drop xdp_aborted xdp_tx_full xdp_invalid_action \
    xdp_tx_errors xdp_rx_refill_errors; do
    stat_delta="$(ethtool_stat_delta \
      "${before_stats}" "${after_stats}" "${stat_name}")" || return 1
    printf -v "${stat_name}_delta" '%s' "${stat_delta}"
    if (( stat_delta != 0 )); then
      echo "driver error/action counter ${stat_name} increased by ${stat_delta}" >&2
      return 1
    fi
  done
}

cleanup() {
  local current_xdp_id

  if [[ -n "${monitor_pid}" ]]; then
    kill -TERM "${monitor_pid}" >/dev/null 2>&1 || true
    wait "${monitor_pid}" >/dev/null 2>&1 || true
    monitor_pid=""
  fi

  if [[ -n "${attached_xdp_id}" ]]; then
    current_xdp_id="$(native_xdp_id || true)"
    if [[ "${current_xdp_id}" == "${attached_xdp_id}" ]]; then
      echo "warning: loader left XDP program ${attached_xdp_id}; refusing an unconditional fallback detach because ownership cannot be checked atomically" >&2
    elif [[ -n "${current_xdp_id}" ]]; then
      echo "warning: current XDP id ${current_xdp_id} differs from our id ${attached_xdp_id}; leaving it untouched" >&2
    fi
  fi
}

if [[ "${NATIVE_XDP_DNS_SMOKE_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0
fi

if [[ -z "${iface}" ]]; then
  usage >&2
  exit 2
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "native XDP smoke is Linux-only" >&2
  exit 1
fi

if [[ "${allow_disruptive}" != "1" ]]; then
  echo "refusing to attach to a physical NIC without ALLOW_DISRUPTIVE=1" >&2
  exit 2
fi

need_cmd awk
need_cmd ethtool
need_cmd ip
need_cmd modinfo
need_cmd sha256sum
need_cmd sudo
need_cmd timeout

if ! sudo -n -v; then
  echo "sudo credentials are not cached; run sudo -v interactively first" >&2
  exit 1
fi

if [[ -z "${traffic_cmd}" ]]; then
  echo "PEER_TRAFFIC_CMD is required and must assert external DNS and ordinary-packet success" >&2
  exit 2
fi
if [[ ! "${duration}" =~ ^[1-9][0-9]*$ ||
      ! "${peer_timeout}" =~ ^[1-9][0-9]*$ ||
      ! "${ttl}" =~ ^[1-9][0-9]*$ ]] ||
   (( duration < peer_timeout + 10 )); then
  echo "DURATION, PEER_TIMEOUT and TTL must be positive integers, with DURATION >= PEER_TIMEOUT + 10" >&2
  exit 2
fi
if (( ttl <= duration )); then
  echo "TTL must be greater than DURATION so the cache cannot expire during the bounded smoke" >&2
  exit 2
fi
if ! validate_completion_requirement "${min_dns_successes}"; then
  exit 2
fi

if [[ -z "${module_file}" || ! -f "${module_file}" ]]; then
  echo "MODULE_FILE must name the exact reviewed r8169.ko artifact" >&2
  exit 2
fi
if [[ ! "${expected_module_sha256}" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "EXPECTED_MODULE_SHA256 must be a 64-digit hexadecimal hash" >&2
  exit 2
fi

actual_module_sha256="$(sha256sum "${module_file}" | awk '{ print $1 }')"
if [[ "${actual_module_sha256,,}" != "${expected_module_sha256,,}" ]]; then
  echo "MODULE_FILE hash ${actual_module_sha256} does not match EXPECTED_MODULE_SHA256" >&2
  exit 1
fi
module_name="$(modinfo -F name "${module_file}")"
module_vermagic="$(modinfo -F vermagic "${module_file}" | awk '{ print $1 }')"
if [[ "${module_name}" != "${expected_driver}" ]]; then
  echo "MODULE_FILE is ${module_name}, expected ${expected_driver}" >&2
  exit 1
fi
if [[ "${module_vermagic}" != "$(uname -r)" ]]; then
  echo "MODULE_FILE vermagic ${module_vermagic} does not match running kernel $(uname -r)" >&2
  exit 1
fi
if [[ ! -d "/sys/module/${expected_driver}" ]]; then
  echo "${expected_driver} is not currently loaded; driver binding is a separate guarded procedure" >&2
  exit 1
fi

if [[ ! -x "${repo_dir}/build/dns_monitor" ||
      ! -f "${repo_dir}/build/dns_xdp_monitor.bpf.o" ]]; then
  echo "missing DNS monitor artifacts; run ./scripts/build_linux.sh first" >&2
  exit 1
fi

if ! ip link show dev "${iface}" >/dev/null 2>&1; then
  echo "interface not found: ${iface}" >&2
  exit 1
fi

driver="$(ethtool -i "${iface}" 2>/dev/null | awk '$1 == "driver:" { print $2 }')"
if [[ -z "${driver}" ]]; then
  echo "unable to determine driver for ${iface}" >&2
  exit 1
fi
if [[ -n "${expected_driver}" && "${driver}" != "${expected_driver}" ]]; then
  echo "refusing driver ${driver}; expected ${expected_driver}" >&2
  exit 1
fi

default_ifaces="$({
  ip -o -4 route show table all default 2>/dev/null || true
  ip -o -6 route show table all default 2>/dev/null || true
} | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }' | sort -u)"

management_iface=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  ssh_peer="${SSH_CONNECTION%% *}"
  if [[ "${ssh_peer}" == *:* ]]; then
    management_iface="$(ip -o -6 route get "${ssh_peer}" 2>/dev/null |
      awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  else
    management_iface="$(ip -o -4 route get "${ssh_peer}" 2>/dev/null |
      awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  fi
fi

stacked_iface=0
if [[ -L "/sys/class/net/${iface}/master" ]] ||
   compgen -G "/sys/class/net/${iface}/upper_*" >/dev/null; then
  stacked_iface=1
fi

if { grep -Fqx -- "${iface}" <<< "${default_ifaces}" ||
     [[ -n "${management_iface}" && "${iface}" == "${management_iface}" ]]; } &&
   [[ "${allow_management_iface}" != "1" ]]; then
  echo "refusing management/default-route interface ${iface}; use local/OOB control or a different-driver management NIC, or set ALLOW_MANAGEMENT_IFACE=1" >&2
  exit 2
fi
if [[ "${stacked_iface}" == "1" && "${allow_management_iface}" != "1" ]]; then
  echo "refusing stacked interface ${iface}; a bond/bridge/VLAN/VRF upper may carry management traffic, so use local/OOB control or set ALLOW_MANAGEMENT_IFACE=1" >&2
  exit 2
fi

existing_xdp_id="$(native_xdp_id)"
if [[ -n "${existing_xdp_id}" ]] ||
   ip -details link show dev "${iface}" | grep -qE 'prog/xdpgeneric|prog/xdpoffload'; then
  echo "refusing to replace an existing XDP program on ${iface}" >&2
  exit 1
fi

mkdir -p "${out_dir}"
trap cleanup EXIT INT TERM

uname -a > "${out_dir}/uname.txt"
ethtool -i "${iface}" > "${out_dir}/ethtool-i.txt"
sha256sum "${module_file}" > "${out_dir}/module-sha256.txt"
modinfo "${module_file}" > "${out_dir}/module-modinfo.txt"
ip -details -statistics link show dev "${iface}" > "${out_dir}/link-before.txt"
cat "/sys/class/net/${iface}/statistics/tx_packets" > \
  "${out_dir}/tx-packets-before.txt"
run_sudo ethtool -S "${iface}" > "${out_dir}/ethtool-stats-before.txt" 2>&1
run_sudo dmesg > "${out_dir}/dmesg-before.txt" 2>&1 || true

pushd "${repo_dir}" >/dev/null
nohup sudo -n timeout "${duration}s" ./build/dns_monitor \
  --dev "${iface}" --hook xdp --role server --xdp-mode native \
  --cache-domain "${domain}" --cache-ip "${answer_ip}" --cache-ttl "${ttl}" \
  > "${out_dir}/dns-monitor.log" 2>&1 &
monitor_pid="$!"
popd >/dev/null

for _ in $(seq 1 50); do
  reported_xdp_id=""
  current_xdp_id=""

  if ! kill -0 "${monitor_pid}" >/dev/null 2>&1; then
    echo "dns_monitor exited before native XDP attached" >&2
    cat "${out_dir}/dns-monitor.log" >&2
    exit 1
  fi

  reported_xdp_id="$(loader_xdp_id "${out_dir}/dns-monitor.log" || true)"
  if [[ -n "${reported_xdp_id}" ]]; then
    if [[ ! "${reported_xdp_id}" =~ ^[1-9][0-9]*$ ]]; then
      echo "dns_monitor reported an invalid XDP program id: ${reported_xdp_id}" >&2
      exit 1
    fi
    current_xdp_id="$(native_xdp_id)"
    if [[ "${current_xdp_id}" != "${reported_xdp_id}" ]]; then
      echo "loader reported XDP id ${reported_xdp_id}, but ${iface} currently has ${current_xdp_id:-none}; refusing to infer ownership" >&2
      exit 1
    fi
    attached_xdp_id="${reported_xdp_id}"
    break
  fi

  # Older dns_monitor loaders predate the xdp_program_id diagnostic.  The
  # attach is still attributable here because this smoke rejected any
  # pre-existing XDP program immediately before launching this one, and the
  # loader is still alive above.  Keep the strict loader/id comparison when a
  # new loader reports its id; this branch is only a compatibility fallback.
  current_xdp_id="$(native_xdp_id || true)"
  if [[ "${current_xdp_id}" =~ ^[1-9][0-9]*$ ]]; then
    attached_xdp_id="${current_xdp_id}"
    echo "dns_monitor did not report an XDP id; using the newly visible native XDP id ${attached_xdp_id}" >&2
    break
  fi
  sleep 0.1
done

if [[ -z "${attached_xdp_id}" ]]; then
  echo "native XDP attach was not visible on ${iface}" >&2
  cat "${out_dir}/dns-monitor.log" >&2
  exit 1
fi

ip -details -statistics link show dev "${iface}" > "${out_dir}/link-attached.txt"
if command -v bpftool >/dev/null 2>&1; then
  run_sudo bpftool net list dev "${iface}" > "${out_dir}/bpftool-net.txt" 2>&1 || true
fi

echo "native XDP id ${attached_xdp_id} attached on ${iface} (driver=${driver})"
assert_owned_xdp "before peer traffic"
echo "running trusted external-peer assertion command"
timeout "${peer_timeout}s" bash -lc "${traffic_cmd}" |
  tee "${out_dir}/peer-traffic.log"
assert_owned_xdp "after peer traffic"
sleep 2
assert_owned_xdp "before loader shutdown"
cat "/sys/class/net/${iface}/statistics/tx_packets" > \
  "${out_dir}/tx-packets-after.txt"
kill -TERM "${monitor_pid}" >/dev/null 2>&1 || true
wait "${monitor_pid}" >/dev/null 2>&1 || true
monitor_pid=""

sleep 1
post_detach_xdp_id="$(native_xdp_id)"
if [[ -n "${post_detach_xdp_id}" ]]; then
  if [[ "${post_detach_xdp_id}" == "${attached_xdp_id}" ]]; then
    echo "dns_monitor exited but its XDP program ${attached_xdp_id} remains attached; refusing to report success" >&2
  else
    echo "XDP program ${post_detach_xdp_id} replaced our program ${attached_xdp_id}; leaving it untouched and refusing to report success" >&2
  fi
  exit 1
fi
ip -details -statistics link show dev "${iface}" > "${out_dir}/link-after.txt"
run_sudo ethtool -S "${iface}" > "${out_dir}/ethtool-stats-after.txt" 2>&1
run_sudo dmesg > "${out_dir}/dmesg-after.txt" 2>&1 || true

post_capture_xdp_id="$(native_xdp_id)"
if [[ -n "${post_capture_xdp_id}" ]]; then
  echo "XDP program ${post_capture_xdp_id} appeared while collecting post-test evidence; refusing to attribute counters to this smoke" >&2
  exit 1
fi

validate_peer_evidence "${out_dir}/peer-traffic.log" "${min_dns_successes}"

cache_hit="$(metric_total cache_hit "${out_dir}/dns-monitor.log" || true)"
cache_tx="$(metric_total cache_tx "${out_dir}/dns-monitor.log" || true)"
cache_hit="${cache_hit:-0}"
cache_tx="${cache_tx:-0}"

if (( cache_hit < expected_dns_tx || cache_tx < expected_dns_tx )); then
  echo "native XDP cache counters did not cover the peer-confirmed queries: expected_dns_tx=${expected_dns_tx} cache_hit=${cache_hit} cache_tx=${cache_tx}" >&2
  exit 1
fi

validate_driver_evidence \
  "${out_dir}/ethtool-stats-before.txt" \
  "${out_dir}/ethtool-stats-after.txt" \
  "${out_dir}/tx-packets-before.txt" \
  "${out_dir}/tx-packets-after.txt" \
  "${expected_dns_tx}"

cat > "${out_dir}/summary.md" <<EOF
# Native XDP DNS Smoke

| field | value |
| --- | --- |
| interface | ${iface} |
| driver | ${driver} |
| xdp_program_id | ${attached_xdp_id} |
| domain | ${domain} |
| answer_ip | ${answer_ip} |
| module_sha256 | ${actual_module_sha256} |
| tx_ring_entries | ${tx_ring_entries} |
| peer_dns_successes_before_sentinel | ${peer_dns_successes} |
| peer_dns_sentinel_after_quiet | ${peer_dns_sentinel} |
| peer_dns_query_bytes | ${peer_dns_query_bytes} |
| peer_dns_response_bytes | ${peer_dns_response_bytes} |
| expected_dns_tx | ${expected_dns_tx} |
| cache_hit | ${cache_hit} |
| cache_tx | ${cache_tx} |
| xdp_pass_delta | ${xdp_pass_delta} |
| xdp_tx_delta | ${xdp_tx_delta} |
| tx_packets_delta | ${tx_packets_delta} |
| xdp_drop_delta | ${xdp_drop_delta} |
| xdp_aborted_delta | ${xdp_aborted_delta} |
| xdp_tx_full_delta | ${xdp_tx_full_delta} |
| xdp_invalid_action_delta | ${xdp_invalid_action_delta} |
| xdp_tx_errors_delta | ${xdp_tx_errors_delta} |
| xdp_rx_refill_errors_delta | ${xdp_rx_refill_errors_delta} |

`cache_hit` and `cache_tx` are totals summed across every one-second
`dns_metrics` delta window, including the final zero window.

Passing this smoke records evidence for driver-mode attach, ordinary-packet
XDP_PASS, DNS `adjust_tail(+16)` and XDP_TX. The peer-confirmed successful
queries exceed the 256-entry ring, the post-quiet sentinel succeeds, and
completion-side `tx_packets` covers the replies while every XDP error counter
stays unchanged. This is a bounded functional completion/reuse test; it does
not prove DMA memory safety, the exact bytes resident in kernel text, reset
paths or sustained stability. Inspect all captured evidence before advancing
the hardware gate.
EOF

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
