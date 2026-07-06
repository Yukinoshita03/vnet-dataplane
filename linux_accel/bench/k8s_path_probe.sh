#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/k8s-path-probe/$(date +%Y%m%d-%H%M%S)}"
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
capture_sudo tc_qdisc tc qdisc show

if command -v kubectl >/dev/null 2>&1; then
  capture kubectl_nodes kubectl get nodes -o wide
  capture kubectl_pods kubectl get pods -A -o wide
  capture kubectl_services kubectl get services -A -o wide
  capture kubectl_cni_pods kubectl get pods -A -o wide -l k8s-app=calico-node
else
  echo "kubectl not found or kubeconfig not configured" > "${out_dir}/kubectl_nodes.log"
  echo "kubectl not found or kubeconfig not configured" > "${out_dir}/kubectl_pods.log"
  echo "kubectl not found or kubeconfig not configured" > "${out_dir}/kubectl_services.log"
  echo "kubectl not found or kubeconfig not configured" > "${out_dir}/kubectl_cni_pods.log"
fi

if command -v crictl >/dev/null 2>&1; then
  capture_sudo crictl_pods crictl pods
else
  echo "crictl not found" > "${out_dir}/crictl_pods.log"
fi

if command -v nerdctl >/dev/null 2>&1; then
  capture_sudo nerdctl_ps nerdctl -n k8s.io ps
else
  echo "nerdctl not found" > "${out_dir}/nerdctl_ps.log"
fi

awk '
  NR == 1 { next }
  {
    name = $1
    sub(/@.*/, "", name)
    if (name ~ /^(cali|flannel|cni|veth|vxlan|genev|br-|cilium|lxc|docker|containerd|kube-ipvs|eth|en)/)
      print name
  }
' "${out_dir}/ip_link.log" | sort -u > "${out_dir}/candidate-ifaces.txt"

candidate_count="$(wc -l < "${out_dir}/candidate-ifaces.txt" | tr -d ' ')"
node_summary="$(first_line_or_empty "${out_dir}/kubectl_nodes.log")"
pod_summary="$(first_line_or_empty "${out_dir}/kubectl_pods.log")"

cat > "${out_dir}/summary.md" <<MD
# Kubernetes Packet Path Probe

This is a read-only probe. It does not create, delete, patch, attach, detach, or mutate Kubernetes, CNI, container runtime, tc, XDP, or eBPF state.

## Candidate tc/XDP Attach Interfaces

Candidate count: ${candidate_count}

\`\`\`text
$(cat "${out_dir}/candidate-ifaces.txt")
\`\`\`

## Environment Signals

| signal | first line |
| --- | --- |
| Kubernetes nodes | \`${node_summary}\` |
| Kubernetes pods | \`${pod_summary}\` |

## Collected Logs

- \`ip_link.log\`
- \`ip_addr.log\`
- \`route.log\`
- \`tc_qdisc.log\`
- \`kubectl_nodes.log\`
- \`kubectl_pods.log\`
- \`kubectl_services.log\`
- \`kubectl_cni_pods.log\`
- \`crictl_pods.log\`
- \`nerdctl_ps.log\`

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
