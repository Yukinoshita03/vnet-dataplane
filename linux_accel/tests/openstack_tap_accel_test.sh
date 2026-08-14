#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
adapter=${repo_dir}/scripts/openstack_tap_accel.sh
mock_ovs=${repo_dir}/tests/mock_ovs_vsctl.sh
mock_monitor=${repo_dir}/tests/mock_dns_monitor.sh
port_id=96696c4a-5746-43ab-8137-241952309dac
expected_tap=tap96696c4a-57
expected_mac=fa:16:3e:a9:61:19
test_root=$(mktemp -d)
adapter_pid=

cleanup() {
  if [ -n "${adapter_pid}" ] && kill -0 "${adapter_pid}" 2>/dev/null; then
    kill -TERM "${adapter_pid}" 2>/dev/null || true
    sleep 0.2
    kill -KILL "${adapter_pid}" 2>/dev/null || true
  fi
  rm -rf "${test_root}"
}
trap cleanup EXIT

actual_tap=$("${adapter}" --resolve-only "${port_id}")
test "${actual_tap}" = "${expected_tap}"
echo "ok - Neutron port UUID resolves to Nova TAP name"

if "${adapter}" --resolve-only not-a-port >/dev/null 2>&1; then
  echo "not ok - invalid Neutron UUID was accepted" >&2
  exit 1
fi
echo "ok - invalid Neutron port UUID is rejected"

mkdir -p "${test_root}/${expected_tap}"
OPENSTACK_PORT_ID=${port_id} \
OPENSTACK_EXPECTED_MAC=${expected_mac} \
SYS_CLASS_NET_ROOT=${test_root} \
OVS_VSCTL_BIN=${mock_ovs} \
MOCK_OVS_IFACE_ID=${port_id} \
MOCK_OVS_ATTACHED_MAC=${expected_mac} \
"${adapter}" --validate-only >/dev/null
echo "ok - matching TAP, iface-id, and MAC are accepted"

if OPENSTACK_PORT_ID=${port_id} \
  OPENSTACK_EXPECTED_MAC=${expected_mac} \
  SYS_CLASS_NET_ROOT=${test_root} \
  OVS_VSCTL_BIN=${mock_ovs} \
  MOCK_OVS_IFACE_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
  MOCK_OVS_ATTACHED_MAC=${expected_mac} \
  "${adapter}" --validate-only >/dev/null 2>&1; then
  echo "not ok - mismatched OVS iface-id was accepted" >&2
  exit 1
fi
echo "ok - mismatched OVS iface-id is rejected"

if OPENSTACK_PORT_ID=${port_id} \
  OPENSTACK_EXPECTED_MAC=${expected_mac} \
  SYS_CLASS_NET_ROOT=${test_root} \
  OVS_VSCTL_BIN=${mock_ovs} \
  MOCK_OVS_IFACE_ID=${port_id} \
  MOCK_OVS_ATTACHED_MAC=fa:16:3e:00:00:01 \
  "${adapter}" --validate-only >/dev/null 2>&1; then
  echo "not ok - mismatched OVS attached-mac was accepted" >&2
  exit 1
fi
echo "ok - mismatched OVS attached-mac is rejected"

policy_file=${test_root}/arp-policy.conf
args_file=${test_root}/monitor-args
touch "${test_root}/dns_xdp_monitor.bpf.o"
printf '%s\n' "${expected_tap} 10.0.0.1 fa:16:3e:aa:bb:cc 30" >"${policy_file}"

OPENSTACK_PORT_ID=${port_id} \
OPENSTACK_EXPECTED_MAC=${expected_mac} \
SYS_CLASS_NET_ROOT=${test_root} \
OVS_VSCTL_BIN=${mock_ovs} \
MOCK_OVS_IFACE_ID=${port_id} \
MOCK_OVS_ATTACHED_MAC=${expected_mac} \
DNS_MONITOR_BIN=${mock_monitor} \
BPF_OBJECT_ROOT=${test_root} \
MOCK_DNS_MONITOR_ARGS_FILE=${args_file} \
OPENSTACK_ARP_POLICY_FILE=${policy_file} \
OPENSTACK_ARP_LEASE_SECONDS=17 \
OPENSTACK_ARP_POLICY_FEED=${test_root}/arp-policy.sock \
OPENSTACK_ARP_POLICY_FEED_UID=1001 \
OPENSTACK_ARP_FEED_STARTUP_TIMEOUT_MS=7000 \
OPENSTACK_ACCEL_ROLE=server \
OPENSTACK_CACHE_DOMAIN=example.test \
OPENSTACK_CACHE_IP=10.0.0.1 \
  "${adapter}" >"${test_root}/adapter.log" 2>&1 &
adapter_pid=$!
for _ in $(seq 1 50); do
  [ -s "${args_file}" ] && break
  sleep 0.1
done
if ! kill -0 "${adapter_pid}" 2>/dev/null || [ ! -s "${args_file}" ]; then
  echo "not ok - OpenStack adapter did not start the monitor" >&2
  cat "${test_root}/adapter.log" >&2
  exit 1
fi
kill -TERM "${adapter_pid}" 2>/dev/null || true
for _ in $(seq 1 30); do
  kill -0 "${adapter_pid}" 2>/dev/null || break
  sleep 0.1
done
kill -KILL "${adapter_pid}" 2>/dev/null || true
wait "${adapter_pid}" 2>/dev/null || true
adapter_pid=
grep -Fx -- "--arp-policy-file" "${args_file}" >/dev/null
grep -Fx -- "${policy_file}" "${args_file}" >/dev/null
grep -Fx -- "--arp-lease-seconds" "${args_file}" >/dev/null
grep -Fx -- "17" "${args_file}" >/dev/null
grep -Fx -- "--arp-policy-feed" "${args_file}" >/dev/null
grep -Fx -- "${test_root}/arp-policy.sock" "${args_file}" >/dev/null
grep -Fx -- "--arp-policy-feed-uid" "${args_file}" >/dev/null
grep -Fx -- "1001" "${args_file}" >/dev/null
grep -Fx -- "--arp-feed-startup-timeout-ms" "${args_file}" >/dev/null
grep -Fx -- "7000" "${args_file}" >/dev/null
echo "ok - OpenStack adapter forwards static policy, lease, and policy feed"

touch "${test_root}/dns_client_cache.bpf.o"
: >"${args_file}"
OPENSTACK_PORT_ID=${port_id} \
OPENSTACK_EXPECTED_MAC=${expected_mac} \
SYS_CLASS_NET_ROOT=${test_root} \
OVS_VSCTL_BIN=${mock_ovs} \
MOCK_OVS_IFACE_ID=${port_id} \
MOCK_OVS_ATTACHED_MAC=${expected_mac} \
DNS_MONITOR_BIN=${mock_monitor} \
BPF_OBJECT_ROOT=${test_root} \
MOCK_DNS_MONITOR_ARGS_FILE=${args_file} \
OPENSTACK_ACCEL_ROLE=client \
OPENSTACK_TRUSTED_DNS=10.0.0.53 \
OPENSTACK_DNS_DETAILED_EVENTS=1 \
  "${adapter}" >"${test_root}/client-adapter.log" 2>&1 &
adapter_pid=$!
for _ in $(seq 1 50); do
  [ -s "${args_file}" ] && break
  sleep 0.1
done
if ! kill -0 "${adapter_pid}" 2>/dev/null || [ ! -s "${args_file}" ]; then
  echo "not ok - client adapter did not start the monitor" >&2
  cat "${test_root}/client-adapter.log" >&2
  exit 1
fi
grep -Fx -- "--detailed-events" "${args_file}" >/dev/null
kill -TERM "${adapter_pid}" 2>/dev/null || true
for _ in $(seq 1 30); do
  kill -0 "${adapter_pid}" 2>/dev/null || break
  sleep 0.1
done
kill -KILL "${adapter_pid}" 2>/dev/null || true
wait "${adapter_pid}" 2>/dev/null || true
adapter_pid=
echo "ok - client adapter enables detailed events explicitly"

if OPENSTACK_PORT_ID=${port_id} \
  OPENSTACK_EXPECTED_MAC=${expected_mac} \
  SYS_CLASS_NET_ROOT=${test_root} \
  OVS_VSCTL_BIN=${mock_ovs} \
  MOCK_OVS_IFACE_ID=${port_id} \
  MOCK_OVS_ATTACHED_MAC=${expected_mac} \
  OPENSTACK_ARP_LEASE_SECONDS=17 \
  OPENSTACK_ACCEL_ROLE=server \
  OPENSTACK_CACHE_DOMAIN=example.test \
  OPENSTACK_CACHE_IP=10.0.0.1 \
  "${adapter}" >/dev/null 2>&1; then
  echo "not ok - lease override was accepted without an ARP policy file" >&2
  exit 1
fi
echo "ok - ARP lease override requires a policy file"
