#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  openstack_tap_accel.sh
  openstack_tap_accel.sh --resolve-only <neutron-port-uuid>
  openstack_tap_accel.sh --validate-only

The service mode reads these environment variables:
  OPENSTACK_PORT_ID             required Neutron port UUID
  OPENSTACK_EXPECTED_MAC        required port MAC address
  OPENSTACK_ACCEL_ROLE          client (default) or server
  OPENSTACK_TRUSTED_DNS         comma-separated resolver IPv4 list for client role
  OPENSTACK_CACHE_FILE          cache policy path for server role
  OPENSTACK_CACHE_DOMAIN/IP     single static entry for server role
  OPENSTACK_CACHE_TTL           static entry TTL, default 300
  OPENSTACK_MAX_LEARN_TTL       learned TTL cap, default 300
  OPENSTACK_LEARN_WINDOW_MS     response learning window, default 2000
  OPENSTACK_DNS_DETAILED_EVENTS 0 (default) or 1 for per-packet ringbuf events
  OPENSTACK_ARP_POLICY_FILE     optional static multi-tap ARP policy path
  OPENSTACK_ARP_LEASE_SECONDS   optional lease override, default policy value
  OPENSTACK_ARP_POLICY_FEED     optional yukinoNet AF_UNIX policy feed socket
  OPENSTACK_ARP_POLICY_FEED_UID optional feed client UID, default monitor UID
  OPENSTACK_ARP_FEED_STARTUP_TIMEOUT_MS startup wait when feed supplies taps
USAGE
}

sys_class_net_root=${SYS_CLASS_NET_ROOT:-/sys/class/net}
ovs_vsctl_bin=${OVS_VSCTL_BIN:-ovs-vsctl}
dns_monitor_bin=${DNS_MONITOR_BIN:-/opt/ebpf-network-service-cache/current/build/dns_monitor}
bpf_object_root=${BPF_OBJECT_ROOT:-/opt/ebpf-network-service-cache/current/build}
poll_seconds=${OPENSTACK_POLL_INTERVAL_SECONDS:-1}
monitor_pid=
sleep_pid=
stopping=0

normalize_port_id() {
  local value=$1
  value=$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')
  if [[ ! ${value} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    echo "invalid Neutron port UUID: ${value}" >&2
    return 2
  fi
  printf '%s' "${value}"
}

tap_name_for_port() {
  local port_id=$1
  printf 'tap%s' "${port_id:0:11}"
}

strip_ovs_value() {
  tr -d '"[:space:]'
}

ovs_external_id() {
  local tap_name=$1
  local key=$2
  "${ovs_vsctl_bin}" --if-exists get Interface "${tap_name}" \
    "external_ids:${key}" 2>/dev/null | strip_ovs_value
}

validate_tap_binding() {
  local port_id=$1
  local expected_mac=$2
  local tap_name=$3
  local actual_port_id
  local actual_mac

  if [ ! -e "${sys_class_net_root}/${tap_name}" ]; then
    echo "tap_missing"
    return 10
  fi

  actual_port_id=$(ovs_external_id "${tap_name}" iface-id)
  if [ "${actual_port_id}" != "${port_id}" ]; then
    echo "ovs_iface_id_mismatch:${actual_port_id:-unset}"
    return 11
  fi

  actual_mac=$(ovs_external_id "${tap_name}" attached-mac | tr '[:upper:]' '[:lower:]')
  if [ "${actual_mac}" != "${expected_mac}" ]; then
    echo "ovs_mac_mismatch:${actual_mac:-unset}"
    return 12
  fi

  echo "ready"
}

sleep_poll() {
  sleep "${poll_seconds}" &
  sleep_pid=$!
  wait "${sleep_pid}" 2>/dev/null || true
  sleep_pid=
}

stop_children() {
  stopping=1
  if [ -n "${sleep_pid}" ]; then
    kill "${sleep_pid}" 2>/dev/null || true
  fi
  if [ -n "${monitor_pid}" ]; then
    kill -INT "${monitor_pid}" 2>/dev/null || true
  fi
}
trap stop_children INT TERM

if [ "${1:-}" = "--resolve-only" ]; then
  [ "$#" -eq 2 ] || { usage; exit 2; }
  resolved_port_id=$(normalize_port_id "$2")
  tap_name_for_port "${resolved_port_id}"
  printf '\n'
  exit 0
fi

port_id=$(normalize_port_id "${OPENSTACK_PORT_ID:-}")
expected_mac=$(printf '%s' "${OPENSTACK_EXPECTED_MAC:-}" | tr '[:upper:]' '[:lower:]')
if [[ ! ${expected_mac} =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]]; then
  echo "invalid OPENSTACK_EXPECTED_MAC: ${expected_mac}" >&2
  exit 2
fi
tap_name=$(tap_name_for_port "${port_id}")

if [ "${1:-}" = "--validate-only" ]; then
  [ "$#" -eq 1 ] || { usage; exit 2; }
  validate_tap_binding "${port_id}" "${expected_mac}" "${tap_name}"
  exit $?
elif [ "$#" -ne 0 ]; then
  usage
  exit 2
fi

role=${OPENSTACK_ACCEL_ROLE:-client}
if [ "${role}" != "client" ] && [ "${role}" != "server" ]; then
  echo "OPENSTACK_ACCEL_ROLE must be client or server" >&2
  exit 2
fi
if [[ ! ${poll_seconds} =~ ^[0-9]+([.][0-9]+)?$ ]] || [ "${poll_seconds}" = "0" ]; then
  echo "OPENSTACK_POLL_INTERVAL_SECONDS must be greater than zero" >&2
  exit 2
fi

detailed_events=${OPENSTACK_DNS_DETAILED_EVENTS:-0}
if [ "${detailed_events}" != "0" ] && [ "${detailed_events}" != "1" ]; then
  echo "OPENSTACK_DNS_DETAILED_EVENTS must be 0 or 1" >&2
  exit 2
fi

monitor_args=(
  --dev "${tap_name}"
  --hook xdp
  --role "${role}"
  --xdp-mode generic
  --timeout-ms 1000
)

arp_policy_file=${OPENSTACK_ARP_POLICY_FILE:-}
if [ -n "${arp_policy_file}" ]; then
  if [ ! -r "${arp_policy_file}" ]; then
    echo "OPENSTACK_ARP_POLICY_FILE is not readable: ${arp_policy_file}" >&2
    exit 2
  fi
  monitor_args+=(--arp-policy-file "${arp_policy_file}")
  if [ -n "${OPENSTACK_ARP_LEASE_SECONDS:-}" ]; then
    if [[ ! ${OPENSTACK_ARP_LEASE_SECONDS} =~ ^[1-9][0-9]*$ ]] ||
      [ "${OPENSTACK_ARP_LEASE_SECONDS}" -gt 86400 ]; then
      echo "OPENSTACK_ARP_LEASE_SECONDS must be between 1 and 86400" >&2
      exit 2
    fi
    monitor_args+=(--arp-lease-seconds "${OPENSTACK_ARP_LEASE_SECONDS}")
  fi
elif [ -n "${OPENSTACK_ARP_LEASE_SECONDS:-}" ]; then
  echo "OPENSTACK_ARP_LEASE_SECONDS requires OPENSTACK_ARP_POLICY_FILE" >&2
  exit 2
fi

arp_policy_feed=${OPENSTACK_ARP_POLICY_FEED:-}
if [ -n "${arp_policy_feed}" ]; then
  monitor_args+=(--arp-policy-feed "${arp_policy_feed}")
  if [ -n "${OPENSTACK_ARP_POLICY_FEED_UID:-}" ]; then
    if [[ ! ${OPENSTACK_ARP_POLICY_FEED_UID} =~ ^[0-9]+$ ]]; then
      echo "OPENSTACK_ARP_POLICY_FEED_UID must be a non-negative integer" >&2
      exit 2
    fi
    monitor_args+=(--arp-policy-feed-uid "${OPENSTACK_ARP_POLICY_FEED_UID}")
  fi
  if [ -n "${OPENSTACK_ARP_FEED_STARTUP_TIMEOUT_MS:-}" ]; then
    if [[ ! ${OPENSTACK_ARP_FEED_STARTUP_TIMEOUT_MS} =~ ^[1-9][0-9]*$ ]]; then
      echo "OPENSTACK_ARP_FEED_STARTUP_TIMEOUT_MS must be greater than zero" >&2
      exit 2
    fi
    monitor_args+=(--arp-feed-startup-timeout-ms
                   "${OPENSTACK_ARP_FEED_STARTUP_TIMEOUT_MS}")
  fi
fi

if [ "${role}" = "client" ]; then
  trusted_dns_csv=${OPENSTACK_TRUSTED_DNS:-}
  if [ -z "${trusted_dns_csv}" ]; then
    echo "OPENSTACK_TRUSTED_DNS is required for client role" >&2
    exit 2
  fi
  bpf_object_path=${bpf_object_root}/dns_client_cache.bpf.o
  monitor_args+=(
    --bpf-object "${bpf_object_path}"
    --max-learn-ttl "${OPENSTACK_MAX_LEARN_TTL:-300}"
    --learn-window-ms "${OPENSTACK_LEARN_WINDOW_MS:-2000}"
  )
  if [ "${detailed_events}" = "1" ]; then
    monitor_args+=(--detailed-events)
  fi
  IFS=',' read -r -a trusted_dns_servers <<<"${trusted_dns_csv}"
  for trusted_dns in "${trusted_dns_servers[@]}"; do
    [ -n "${trusted_dns}" ] || continue
    monitor_args+=(--trusted-dns "${trusted_dns}")
  done
else
  bpf_object_path=${bpf_object_root}/dns_xdp_monitor.bpf.o
  monitor_args+=(--bpf-object "${bpf_object_path}")
  cache_file=${OPENSTACK_CACHE_FILE:-}
  cache_domain=${OPENSTACK_CACHE_DOMAIN:-}
  cache_ip=${OPENSTACK_CACHE_IP:-}
  if [ -n "${cache_file}" ]; then
    monitor_args+=(--cache-file "${cache_file}")
  elif [ -n "${cache_domain}" ] && [ -n "${cache_ip}" ]; then
    monitor_args+=(
      --cache-domain "${cache_domain}"
      --cache-ip "${cache_ip}"
      --cache-ttl "${OPENSTACK_CACHE_TTL:-300}"
    )
  else
    echo "server role requires OPENSTACK_CACHE_FILE or domain/IP" >&2
    exit 2
  fi
fi

test -x "${dns_monitor_bin}"
test -r "${bpf_object_path}"

last_state=
while [ "${stopping}" -eq 0 ]; do
  set +e
  binding_state=$(validate_tap_binding "${port_id}" "${expected_mac}" "${tap_name}")
  binding_rc=$?
  set -e
  if [ "${binding_rc}" -ne 0 ]; then
    if [ "${binding_state}" != "${last_state}" ]; then
      echo "openstack_tap_accel state=waiting tap=${tap_name} reason=${binding_state}"
      last_state=${binding_state}
    fi
    sleep_poll
    continue
  fi

  echo "openstack_tap_accel state=attaching tap=${tap_name} port=${port_id} role=${role}"
  "${dns_monitor_bin}" "${monitor_args[@]}" &
  monitor_pid=$!
  last_state=attached

  while kill -0 "${monitor_pid}" 2>/dev/null; do
    sleep_poll
    [ "${stopping}" -eq 0 ] || break
    set +e
    binding_state=$(validate_tap_binding "${port_id}" "${expected_mac}" "${tap_name}")
    binding_rc=$?
    set -e
    if [ "${binding_rc}" -ne 0 ]; then
      echo "openstack_tap_accel state=detaching tap=${tap_name} reason=${binding_state}"
      kill -INT "${monitor_pid}" 2>/dev/null || true
      break
    fi
  done

  set +e
  wait "${monitor_pid}"
  monitor_rc=$?
  set -e
  monitor_pid=
  [ "${stopping}" -eq 0 ] || break
  echo "openstack_tap_accel state=monitor-exited tap=${tap_name} rc=${monitor_rc}"
  sleep_poll
done

echo "openstack_tap_accel state=stopped tap=${tap_name}"
