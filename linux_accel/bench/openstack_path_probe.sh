#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/openstack-path-probe/$(date +%Y%m%d-%H%M%S)}"
sudo_pass="${SUDO_PASS:-}"

run_sudo() {
  if [[ -n "${sudo_pass}" ]]; then
    printf '%s\n' "${sudo_pass}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

capture() {
  local name="$1"
  shift
  {
    echo "\$ $*"
    "$@"
  } > "${out_dir}/${name}.log" 2>&1 || true
}

capture_sudo() {
  local name="$1"
  shift
  {
    echo "\$ sudo $*"
    run_sudo "$@"
  } > "${out_dir}/${name}.log" 2>&1 || true
}

first_line_or_empty() {
  local file="$1"
  if [[ -s "${file}" ]]; then
    head -1 "${file}"
  fi
}

mkdir -p "${out_dir}"

capture uname uname -a
capture ip_link ip -br link
capture ip_addr ip -br addr
capture route ip route
capture bridge_link bridge link show
capture_sudo tc_qdisc tc qdisc show

if command -v ovs-vsctl >/dev/null 2>&1; then
  capture_sudo ovs_bridges ovs-vsctl list-br
  capture_sudo ovs_ports ovs-vsctl show
else
  echo "ovs-vsctl not found" > "${out_dir}/ovs_bridges.log"
  echo "ovs-vsctl not found" > "${out_dir}/ovs_ports.log"
fi

if command -v virsh >/dev/null 2>&1; then
  capture_sudo virsh_domains virsh list --all
  capture_sudo virsh_ifaces virsh domiflist --all
else
  echo "virsh not found" > "${out_dir}/virsh_domains.log"
  echo "virsh not found" > "${out_dir}/virsh_ifaces.log"
fi

if command -v openstack >/dev/null 2>&1; then
  capture openstack_hypervisors openstack hypervisor list
  capture openstack_servers openstack server list --all-projects
  capture openstack_networks openstack network list
  capture openstack_ports openstack port list
else
  echo "openstack CLI not found or openrc not sourced" > "${out_dir}/openstack_hypervisors.log"
  echo "openstack CLI not found or openrc not sourced" > "${out_dir}/openstack_servers.log"
  echo "openstack CLI not found or openrc not sourced" > "${out_dir}/openstack_networks.log"
  echo "openstack CLI not found or openrc not sourced" > "${out_dir}/openstack_ports.log"
fi

awk '
  NR == 1 { next }
  {
    name = $1
    sub(/@.*/, "", name)
    if (name ~ /^(tap|qvb|qvo|qbr|qr-|qg-|br-|ovs|vnet|virbr|veth|genev|vxlan|ovn|en|eth)/)
      print name
  }
' "${out_dir}/ip_link.log" | sort -u > "${out_dir}/candidate-ifaces.txt"

candidate_count="$(wc -l < "${out_dir}/candidate-ifaces.txt" | tr -d ' ')"
ovs_summary="$(first_line_or_empty "${out_dir}/ovs_bridges.log")"
virsh_summary="$(first_line_or_empty "${out_dir}/virsh_domains.log")"
openstack_summary="$(first_line_or_empty "${out_dir}/openstack_hypervisors.log")"

cat > "${out_dir}/summary.md" <<MD
# OpenStack / KVM Packet Path Probe

This is a read-only probe. It does not create, delete, attach, detach, migrate, or modify OpenStack, libvirt, OVS, bridge, or eBPF state.

## Candidate tc/XDP Attach Interfaces

Candidate count: ${candidate_count}

\`\`\`text
$(cat "${out_dir}/candidate-ifaces.txt")
\`\`\`

## Environment Signals

| signal | first line |
| --- | --- |
| OVS bridges | \`${ovs_summary}\` |
| libvirt domains | \`${virsh_summary}\` |
| OpenStack hypervisors | \`${openstack_summary}\` |

## Collected Logs

- \`ip_link.log\`
- \`ip_addr.log\`
- \`bridge_link.log\`
- \`tc_qdisc.log\`
- \`ovs_bridges.log\`
- \`ovs_ports.log\`
- \`virsh_domains.log\`
- \`virsh_ifaces.log\`
- \`openstack_hypervisors.log\`
- \`openstack_servers.log\`
- \`openstack_networks.log\`
- \`openstack_ports.log\`

## How To Use

Use the candidate interface list to choose where to attach the existing tc monitors:

\`\`\`bash
sudo ./build/dns_monitor --dev <candidate-iface> --hook tc
sudo ./build/grpc_monitor --dev <candidate-iface> --port 50051
\`\`\`

For DNS cache acceleration, use XDP only on interfaces that support generic or native XDP:

\`\`\`bash
sudo ./build/dns_monitor --dev <candidate-iface> --hook xdp --xdp-mode generic --cache-file cache-policy.txt
\`\`\`
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
