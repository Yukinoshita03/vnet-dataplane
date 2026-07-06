#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/k8s-workload-evidence/$(date +%Y%m%d-%H%M%S)}"
sudo_pass="${SUDO_PASS:-}"
namespace="${NAMESPACE:-ebpf-evidence}"
iface="${IFACE:-}"
iface_regex="${IFACE_REGEX:-^(cali|flannel|cni|veth|vxlan|genev|br-|docker|lxc|eth|en)}"
grpc_port="${GRPC_PORT:-50051}"
grpc_monitor_port="${GRPC_MONITOR_PORT:-80}"
grpc_iface="${GRPC_IFACE:-}"
requests="${REQUESTS:-1000}"
warmup="${WARMUP:-50}"
duration="${DURATION:-10}"
workload_image="${K8S_WORKLOAD_IMAGE:-nginx:alpine}"
keep_resources="${KEEP_RESOURCES:-0}"

run_sudo() {
  if [[ -n "${sudo_pass}" ]]; then
    printf '%s\n' "${sudo_pass}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
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

choose_iface() {
  if [[ -n "${iface}" ]]; then
    echo "${iface}"
    return 0
  fi
  ip -br link | awk -v re="${iface_regex}" '
    {
      name=$1
      sub(/@.*/, "", name)
      if (name ~ /^(cni0|flannel|cali|veth|lxc|vxlan|genev)/)
        preferred[++p] = name
      else if (name ~ /^br-/ && name !~ /^br-(ex|int)$/)
        preferred[++p] = name
      else if (name ~ re && name !~ /^(br-ex|br-int|ovs-system)$/)
        fallback[++f] = name
    }
    END {
      if (p > 0) print preferred[1]
      else if (f > 0) print fallback[1]
    }
  '
}

cleanup() {
  run_sudo pkill -TERM -f "dns_monitor --dev ${workload_iface:-}" >/dev/null 2>&1 || true
  run_sudo pkill -TERM -f "grpc_monitor --dev ${workload_iface:-}" >/dev/null 2>&1 || true
  if [[ "${keep_resources}" != "1" ]]; then
    kubectl delete namespace "${namespace}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  fi
}

wait_pod_ready() {
  local pod="$1"
  kubectl -n "${namespace}" wait --for=condition=Ready "pod/${pod}" --timeout=180s >/dev/null
}

start_monitor() {
  local name="$1"
  shift
  local log="${out_dir}/${name}.log"
  if [[ -n "${sudo_pass}" ]]; then
    (cd "${repo_dir}" && printf '%s\n' "${sudo_pass}" | sudo -S timeout --signal=INT --kill-after=2s "${duration}s" "$@") > "${log}" 2>&1 &
  else
    (cd "${repo_dir}" && sudo timeout --signal=INT --kill-after=2s "${duration}s" "$@") > "${log}" 2>&1 &
  fi
  echo $!
}

write_manifests() {
  cat > "${out_dir}/grpc-server.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: grpc-echo
  namespace: ${namespace}
  labels:
    app: grpc-echo
spec:
  containers:
  - name: server
    image: ${workload_image}
    imagePullPolicy: IfNotPresent
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: grpc-echo
  namespace: ${namespace}
spec:
  selector:
    app: grpc-echo
  ports:
  - name: grpc
    port: ${grpc_port}
    targetPort: 80
YAML
}

run_grpc_client() {
  local service_ip="$1"
  kubectl -n "${namespace}" run grpc-client \
    --restart=Never \
    --image="${workload_image}" \
    --image-pull-policy=IfNotPresent \
    --command -- sh -c "
      ok=0; fail=0; total=$((requests + warmup)); start=\$(date +%s);
      i=0; while [ \$i -lt \$total ]; do
        if wget -q -T 2 -O /dev/null http://${service_ip}:${grpc_port}/; then
          if [ \$i -ge ${warmup} ]; then ok=\$((ok + 1)); fi
        else
          fail=\$((fail + 1));
        fi
        i=\$((i + 1));
      done;
      end=\$(date +%s); elapsed=\$((end - start)); [ \$elapsed -lt 1 ] && elapsed=1;
      qps=\$(awk -v ok=\$ok -v elapsed=\$elapsed 'BEGIN { printf \"%.2f\", ok / elapsed }');
      echo count=\$ok failed=\$fail qps=\$qps transport=http-over-service service_ip=${service_ip};
      [ \$ok -gt 0 ];
    " > "${out_dir}/grpc-client-create.log"
  kubectl -n "${namespace}" wait --for=condition=Ready pod/grpc-client --timeout=60s >/dev/null 2>&1 || true
  kubectl -n "${namespace}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/grpc-client --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "${namespace}" logs grpc-client > "${out_dir}/grpc-client.log" 2>&1 || true
}

run_dns_client() {
  local dns_ip="$1"
  kubectl -n "${namespace}" run dns-client \
    --restart=Never \
    --image="${workload_image}" \
    --image-pull-policy=IfNotPresent \
    --command -- sh -c "
      ok=0; fail=0; total=$((requests + warmup)); start=\$(date +%s);
      i=0; while [ \$i -lt \$total ]; do
        if nslookup kubernetes.default.svc.cluster.local ${dns_ip} >/dev/null 2>&1; then
          if [ \$i -ge ${warmup} ]; then ok=\$((ok + 1)); fi
        else
          fail=\$((fail + 1));
        fi
        i=\$((i + 1));
      done;
      end=\$(date +%s); elapsed=\$((end - start)); [ \$elapsed -lt 1 ] && elapsed=1;
      qps=\$(awk -v ok=\$ok -v elapsed=\$elapsed 'BEGIN { printf \"%.2f\", ok / elapsed }');
      echo count=\$ok failed=\$fail qps=\$qps dns_server=${dns_ip};
      [ \$ok -gt 0 ];
    " > "${out_dir}/dns-client-create.log"
  kubectl -n "${namespace}" wait --for=condition=Ready pod/dns-client --timeout=60s >/dev/null 2>&1 || true
  kubectl -n "${namespace}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/dns-client --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "${namespace}" logs dns-client > "${out_dir}/dns-client.log" 2>&1 || true
}

need_cmd kubectl
need_cmd ip
need_cmd awk
if [[ ! -x "${repo_dir}/build/dns_monitor" || ! -x "${repo_dir}/build/grpc_monitor" ]]; then
  echo "missing monitor binaries; run ./scripts/build_linux.sh first" >&2
  exit 1
fi

mkdir -p "${out_dir}"
trap cleanup EXIT

if ! kubectl get nodes >/dev/null 2>&1; then
  cat > "${out_dir}/summary.md" <<MD
# Kubernetes Workload Evidence

Kubernetes is not reachable from the current kubeconfig. No cluster mutation was performed.

Run this script on a Kubernetes node or configure kubeconfig first. If the VM has kind/k3s installed, create the single-node cluster before rerunning this script.
MD
  cat "${out_dir}/summary.md"
  echo "Artifacts: ${out_dir}"
  exit 1
fi

workload_iface="$(choose_iface)"
if [[ -z "${workload_iface}" ]]; then
  echo "No candidate Kubernetes interface found; set IFACE=<node-interface>" >&2
  exit 1
fi

capture uname uname -a
capture ip_link ip -br link
capture ip_addr ip -br addr
capture route ip route
capture_sudo tc_qdisc tc qdisc show
capture kubectl_nodes kubectl get nodes -o wide
capture kubectl_pods_before kubectl get pods -A -o wide
ip -br link show "${workload_iface}" > "${out_dir}/workload-iface.log" 2>&1 || true

kubectl create namespace "${namespace}" >/dev/null 2>&1 || true
write_manifests
kubectl apply -f "${out_dir}/grpc-server.yaml" > "${out_dir}/kubectl-apply.log"
wait_pod_ready grpc-echo
capture kubectl_pods_after kubectl get pods -A -o wide
capture kubectl_services_after kubectl get services -A -o wide
grpc_service_ip="$(kubectl -n "${namespace}" get svc grpc-echo -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
grpc_pod_ip="$(kubectl -n "${namespace}" get pod grpc-echo -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
grpc_pod_mac=""
grpc_pod_veth=""
if [[ -z "${grpc_iface}" ]]; then
  grpc_sandbox_id="$(run_sudo crictl -r unix:///run/containerd/containerd.sock pods --namespace "${namespace}" --name grpc-echo -q 2>/dev/null | head -1 || true)"
  if [[ -n "${grpc_sandbox_id}" ]]; then
    cni_result="/var/lib/cni/results/cbr0-${grpc_sandbox_id}-eth0"
    grpc_pod_veth="$(run_sudo cat "${cni_result}" 2>/dev/null | grep -o '"name":"veth[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  fi
fi
if [[ -z "${grpc_iface}" && -z "${grpc_pod_veth}" && -n "${grpc_pod_ip}" && "${workload_iface}" == "cni0" ]]; then
  grpc_pod_mac="$(ip neigh show "${grpc_pod_ip}" dev cni0 | awk '{ print $5; exit }')"
  if [[ -n "${grpc_pod_mac}" ]]; then
    grpc_pod_veth="$(bridge fdb show br cni0 | awk -v mac="${grpc_pod_mac}" '$1 == mac { print $3; exit }')"
  fi
fi
if [[ -z "${grpc_iface}" ]]; then
  grpc_iface="${grpc_pod_veth:-${workload_iface}}"
fi

dns_ip="$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [[ -z "${dns_ip}" ]]; then
  dns_ip="$(kubectl -n kube-system get svc coredns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
fi

dns_status="skipped: kube-dns/coredns service not found"
if [[ -n "${dns_ip}" ]]; then
  dns_pid="$(start_monitor dns-monitor "${repo_dir}/build/dns_monitor" --dev "${workload_iface}" --hook tc --timeout-ms 1000)"
  sleep 1
  run_dns_client "${dns_ip}" || true
  run_sudo pkill -TERM -f "dns_monitor --dev ${workload_iface}" >/dev/null 2>&1 || true
  wait "${dns_pid}" >/dev/null 2>&1 || true
  dns_status="$(cat "${out_dir}/dns-client.log" 2>/dev/null || true)"
else
  echo "${dns_status}" > "${out_dir}/dns-client.log"
fi

grpc_pid="$(start_monitor grpc-monitor "${repo_dir}/build/grpc_monitor" --dev "${grpc_iface}" --port "${grpc_monitor_port}" --timeout-ms 1000)"
sleep 1
run_grpc_client "${grpc_service_ip}" || true
run_sudo pkill -TERM -f "grpc_monitor --dev ${grpc_iface}" >/dev/null 2>&1 || true
wait "${grpc_pid}" >/dev/null 2>&1 || true

grpc_status="$(cat "${out_dir}/grpc-client.log" 2>/dev/null || true)"
dns_metrics="$(grep 'dns_metrics' "${out_dir}/dns-monitor.log" | awk '/qps=[1-9]|rps=[1-9]/ { line=$0 } END { if (line) print line }' || true)"
if [[ -z "${dns_metrics}" ]]; then
  dns_metrics="$(grep -E 'dns_metrics|query|response|ringbuf|events' "${out_dir}/dns-monitor.log" | tail -1 || true)"
fi
grpc_metrics="$(grep 'grpc_metrics' "${out_dir}/grpc-monitor.log" | awk '/reqps=[1-9]|resps=[1-9]/ { line=$0 } END { if (line) print line }' || true)"
if [[ -z "${grpc_metrics}" ]]; then
  grpc_metrics="$(grep 'grpc_metrics' "${out_dir}/grpc-monitor.log" | tail -1 || true)"
fi

cat > "${out_dir}/summary.md" <<MD
# Kubernetes Pod Workload Evidence

| field | value |
| --- | --- |
| namespace | ${namespace} |
| workload_iface | ${workload_iface} |
| grpc_monitor_iface | ${grpc_iface} |
| grpc_pod_ip | ${grpc_pod_ip:-not-found} |
| grpc_pod_veth | ${grpc_pod_veth:-not-found} |
| workload_image | ${workload_image} |
| grpc_service | grpc-echo:${grpc_port} |
| grpc_monitor_port | ${grpc_monitor_port} |
| grpc_service_ip | ${grpc_service_ip:-not-found} |
| dns_service_ip | ${dns_ip:-not-found} |
| requests | ${requests} |
| warmup | ${warmup} |

## Results

DNS Pod-to-Service client: ${dns_status}

gRPC Pod-to-Service client: ${grpc_status}

DNS monitor: ${dns_metrics}

gRPC monitor: ${grpc_metrics}

## Collected Evidence

- \`kubectl_nodes.log\`
- \`kubectl_pods_before.log\`
- \`kubectl_pods_after.log\`
- \`kubectl_services_after.log\`
- \`ip_link.log\`
- \`tc_qdisc.log\`
- \`workload-iface.log\`
- \`dns-monitor.log\`
- \`grpc-monitor.log\`
- \`dns-client.log\`
- \`grpc-client.log\`

The script deletes namespace \`${namespace}\` on exit unless \`KEEP_RESOURCES=1\` is set.
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
