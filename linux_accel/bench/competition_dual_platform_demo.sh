#!/usr/bin/env bash
set -Eeuo pipefail

# One competition-facing entry point for the two deployment shapes that this
# repository can demonstrate today:
#
#   VM/OpenStack: OVS/TAP path, generic XDP fast path, tc observation
#   Kubernetes:   CNI/Pod-veth path, tc observation and workload evidence
#
# The default mode is "plan" and does not touch either environment.  "preflight"
# only runs read-only probes.  "live" is intentionally opt-in because it creates
# a temporary Kubernetes namespace and attaches short-lived tc programs.

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="${1:-both}"
mode="${2:-plan}"
raw_run_id="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
run_id="$(printf '%s' "${raw_run_id}" | tr -cd 'A-Za-z0-9_.-')"
if [[ -z "${run_id}" ]]; then
  echo "RUN_ID must contain at least one alphanumeric, dot, underscore or hyphen" >&2
  exit 2
fi
out_dir="${OUT_DIR:-${repo_dir}/artifacts/competition-demo/${run_id}}"
kubeconfig="${SCHOOL_K8S_KUBECONFIG:-${KUBECONFIG:-/Users/tankaiwen/.kube/school-k8s.yaml}}"
sudo_pass="${SUDO_PASS:-}"
cluster_ssh="${CLUSTER_SSH:-/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-ssh.sh}"
cluster_copy="${CLUSTER_COPY:-/Users/tankaiwen/.codex/skills/deploy-school-cluster/scripts/cluster-copy.sh}"
remote_stage_dir="${REMOTE_STAGE_DIR:-/tmp/linux-accel-competition-demo-${run_id}}"
remote_monitor_bin_dir="${REMOTE_MONITOR_BIN_DIR:-/opt/ebpf-network-service-cache/current/build}"
vm_node="${VM_NODE-node1}"
k8s_node="${K8S_NODE-node1}"
remote_run_as_root=0

case "${platform}" in
  vm|k8s|both) ;;
  *)
    echo "usage: $0 [vm|k8s|both] [plan|preflight|live]" >&2
    exit 2
    ;;
esac

case "${mode}" in
  plan|preflight|live) ;;
  *)
    echo "usage: $0 [vm|k8s|both] [plan|preflight|live]" >&2
    exit 2
    ;;
esac

if [[ "${mode}" == "live" && "${CONFIRM_LIVE:-0}" != "1" ]]; then
  cat >&2 <<'EOF'
live mode is deliberately opt-in. Re-run with CONFIRM_LIVE=1 after checking
the target interfaces and workload parameters.
EOF
  exit 2
fi

mkdir -p "${out_dir}"

cleanup_remote_runs() {
  local node
  [[ "${remote_stage_dir}" =~ ^/tmp/linux-accel-competition-demo-[A-Za-z0-9_.-]+$ ]] || return 0
  for node in "${vm_node}" "${k8s_node}"; do
    [[ -r "${out_dir}/.remote-${node}.rc" ]] || continue
    [[ "$(cat "${out_dir}/.remote-${node}.rc")" == "0" ]] || continue
    "${cluster_ssh}" "${node}" -- \
      "sudo -n rm -rf -- $(shell_quote "${remote_stage_dir}")" >/dev/null 2>&1 || true
  done
}
trap cleanup_remote_runs EXIT

run_sudo() {
  if [[ -n "${sudo_pass}" ]]; then
    printf '%s\n' "${sudo_pass}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

record() {
  local name="$1"
  shift
  local log="${CURRENT_OUT}/${name}.log"
  local rc

  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    if "$@"; then
      rc=0
    else
      rc=$?
    fi
  } >"${log}" 2>&1
  printf '%s\n' "${rc}" >"${CURRENT_OUT}/${name}.rc"
  return 0
}

record_env_script() {
  local name="$1"
  local script="$2"
  shift 2
  local log="${CURRENT_OUT}/${name}.log"
  local rc

  {
    printf '$ %s' "${script}"
    printf ' %q' "$@"
    printf '\n'
    if env "$@" bash "${repo_dir}/${script}"; then
      rc=0
    else
      rc=$?
    fi
  } >"${log}" 2>&1
  printf '%s\n' "${rc}" >"${CURRENT_OUT}/${name}.rc"
  return 0
}

shell_quote() {
  printf '%q' "$1"
}

write_unavailable() {
  local name="$1"
  local reason="$2"
  printf '%s\n' "${reason}" >"${CURRENT_OUT}/${name}.log"
  printf 'skipped\n' >"${CURRENT_OUT}/${name}.rc"
  case "${name}" in
    path_probe|path-probe|tc-attach-smoke|workload-evidence|udp-fastpath)
      mkdir -p "${CURRENT_OUT}/${name}"
      {
        printf '# %s skipped\n\n%s\n' "${name}" "${reason}"
      } >"${CURRENT_OUT}/${name}/summary.md"
      ;;
  esac
}

remote_node_available() {
  local target_node="$1"
  local status_file="${out_dir}/.remote-${target_node}.rc"
  local log_file="${out_dir}/remote-${target_node}.log"
  local rc

  if [[ -r "${status_file}" ]]; then
    [[ "$(cat "${status_file}")" == "0" ]]
    return
  fi

  if "${cluster_ssh}" "${target_node}" -- 'hostname' >"${log_file}" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "${rc}" >"${status_file}"
  [[ "${rc}" -eq 0 ]]
}

record_remote_env_script() {
  local name="$1"
  local target_node="$2"
  local script="$3"
  local remote_out="$4"
  shift 4
  local remote_script="${remote_stage_dir}/bench/$(basename "${script}")"
  local log="${CURRENT_OUT}/${name}.log"
  local rc=0
  local env_args=()
  local arg

  for arg in "$@"; do
    env_args+=("$(shell_quote "${arg}")")
  done

  {
    printf '$ remote %s %s' "${target_node}" "${script}"
    printf ' %q' "$@"
    printf '\n'
    if "${cluster_ssh}" "${target_node}" -- \
      "mkdir -p $(shell_quote "${remote_stage_dir}/bench")"; then
      :
    else
      rc=$?
    fi
    if [[ "${rc}" -eq 0 ]]; then
      if "${cluster_copy}" "${repo_dir}/${script}" "${remote_stage_dir}/bench/" "${target_node}"; then
        :
      else
        rc=$?
      fi
    fi
    if [[ "${rc}" -eq 0 ]]; then
      local remote_command="env OUT_DIR=$(shell_quote "${remote_out}") ${env_args[*]} bash $(shell_quote "${remote_script}")"
      if [[ "${remote_run_as_root}" == "1" ]]; then
        remote_command="sudo -n ${remote_command}"
      fi
      if "${cluster_ssh}" "${target_node}" -- "${remote_command}"; then
        :
      else
        rc=$?
      fi
    fi
  } >"${log}" 2>&1
  printf '%s\n' "${rc}" >"${CURRENT_OUT}/${name}.rc"

  local summary_name="${name}-summary.md"
  local summary_log="${CURRENT_OUT}/${summary_name}"
  local summary_rc=0
  {
    if "${cluster_ssh}" "${target_node}" -- \
      "test -r $(shell_quote "${remote_out}/summary.md") && cat $(shell_quote "${remote_out}/summary.md")"; then
      :
    else
      summary_rc=$?
    fi
  } >"${summary_log}" 2>&1
  printf '%s\n' "${summary_rc}" >"${CURRENT_OUT}/${name}-summary.rc"
}

record_remote_command() {
  local name="$1"
  local target_node="$2"
  shift 2
  local log="${CURRENT_OUT}/${name}.log"
  local rc=0
  if ! remote_node_available "${target_node}"; then
    write_unavailable "${name}" \
      "Remote ${target_node} is not reachable. See ${out_dir}/remote-${target_node}.log; no remote state was changed."
    return 0
  fi
  {
    printf '$ remote %s' "${target_node}"
    printf ' %q' "$@"
    printf '\n'
    if "${cluster_ssh}" "${target_node}" -- "$@"; then
      :
    else
      rc=$?
    fi
  } >"${log}" 2>&1
  printf '%s\n' "${rc}" >"${CURRENT_OUT}/${name}.rc"
}

run_target_script() {
  local name="$1"
  local script="$2"
  local target_node="$3"
  local local_out="${CURRENT_OUT}/${name}"
  shift 3
  local local_args=()
  local arg

  for arg in "$@"; do
    [[ "${arg}" == OUT_DIR=* ]] && continue
    local_args+=("${arg}")
  done

  if [[ -n "${target_node}" ]]; then
    if ! remote_node_available "${target_node}"; then
      write_unavailable "${name}" \
        "Remote ${target_node} is not reachable. See ${out_dir}/remote-${target_node}.log; no remote state was changed."
      return 0
    fi
    if [[ "${#local_args[@]}" -gt 0 ]]; then
      record_remote_env_script "${name}" "${target_node}" "${script}" \
        "${remote_stage_dir}/${CURRENT_PLATFORM}/${name}" \
        "MONITOR_BIN_DIR=${remote_monitor_bin_dir}" "${local_args[@]}"
    else
      record_remote_env_script "${name}" "${target_node}" "${script}" \
        "${remote_stage_dir}/${CURRENT_PLATFORM}/${name}" \
        "MONITOR_BIN_DIR=${remote_monitor_bin_dir}"
    fi
    copy_remote_tree "${target_node}" \
      "${remote_stage_dir}/${CURRENT_PLATFORM}/${name}" "${local_out}" || true
    return 0
  fi

  if [[ "$(uname -s)" == "Linux" || "${RUN_LOCAL_HOST_PROBE:-0}" == "1" ]]; then
    if [[ "${#local_args[@]}" -gt 0 ]]; then
      record_env_script "${name}" "${script}" \
        "OUT_DIR=${local_out}" "MONITOR_BIN_DIR=${MONITOR_BIN_DIR:-${repo_dir}/build}" \
        "${local_args[@]}"
    else
      record_env_script "${name}" "${script}" \
        "OUT_DIR=${local_out}" "MONITOR_BIN_DIR=${MONITOR_BIN_DIR:-${repo_dir}/build}"
    fi
    return 0
  fi

  write_unavailable "${name}" \
    "Skipped on $(uname -s) staging host. Set ${CURRENT_PLATFORM^^}_NODE=<node1|node2|node3> to run ${script} on a Linux cluster node; no remote state was changed."
}

record_shell() {
  local name="$1"
  shift
  local log="${CURRENT_OUT}/${name}.log"
  local rc

  {
    if bash -lc "$*"; then
      rc=0
    else
      rc=$?
    fi
  } >"${log}" 2>&1
  printf '%s\n' "${rc}" >"${CURRENT_OUT}/${name}.rc"
  return 0
}

read_rc() {
  local file="$1"
  if [[ -r "${file}" ]]; then
    cat "${file}"
  else
    printf 'not-run\n'
  fi
}

copy_summary() {
  local source="$1"
  local target_name="$2"
  if [[ -r "${source}" ]]; then
    cp "${source}" "${CURRENT_OUT}/${target_name}"
  else
    printf 'No summary was produced.\n' >"${CURRENT_OUT}/${target_name}"
  fi
}

copy_named_summary() {
  local name="$1"
  local target_name="$2"
  if [[ -r "${CURRENT_OUT}/${name}/summary.md" ]]; then
    cp "${CURRENT_OUT}/${name}/summary.md" "${CURRENT_OUT}/${target_name}"
  elif [[ -r "${CURRENT_OUT}/${name}-summary.md" ]]; then
    cp "${CURRENT_OUT}/${name}-summary.md" "${CURRENT_OUT}/${target_name}"
  else
    printf 'No summary was produced for %s.\n' "${name}" >"${CURRENT_OUT}/${target_name}"
  fi
}

copy_remote_tree() {
  local target_node="$1"
  local remote_out="$2"
  local local_out="$3"
  local log="${CURRENT_OUT}/$(basename "${local_out}")-fetch.log"
  local rc=0

  mkdir -p "${local_out}"
  if {
    "${cluster_ssh}" "${target_node}" -- \
      "tar -C $(shell_quote "${remote_out}") -czf - ." \
      | sed '1d' \
      | tar -xzf - -C "${local_out}"
  } >"${log}" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "${rc}" >"${CURRENT_OUT}/$(basename "${local_out}")-fetch.rc"
  return "${rc}"
}

write_plan() {
  cat >"${out_dir}/demo-card.md" <<'MD'
# Linux Accel 双平台比赛展示卡

这套展示用同一套协议逻辑，切换两个部署路径：

| 展示面 | OpenStack 虚拟机 | Kubernetes |
| --- | --- | --- |
| 数据路径 | OVS `br-int` / TAP / veth | CNI / Pod veth / overlay |
| XDP 重点 | DNS/确定性 UDP generic XDP exact-hit、miss fail-open | 当前先展示 Pod 路径与观测；Pod-veth XDP 需在 agent/image 验证后启用 |
| TC 重点 | gRPC 流量可见性 | gRPC/服务流量可见性 |
| 业务证据 | VM workload 或 OpenStack TAP fastpath | Pod-to-Service workload |
| 不能混淆 | gRPC/LDAP 不是 XDP 快路径 | K8s workload evidence 不是 native NIC XDP |

## 现场顺序

1. 先展示 `preflight` 生成的拓扑和 hook 证据。
2. 运行 VM 版：先看 tc attach，再看 DNS/UDP hit、miss 和后端计数不变。
3. 运行 K8s 版：看 CNI、Pod veth、Service 和 DNS/TC monitor 计数。
4. 最后用同一张对比表说明：XDP 只处理确定性短 UDP；gRPC/LDAP 走 TC/用户态，非法、miss、超时均 fail-open。

## 运行命令

```bash
# 只生成展示卡，不碰集群
./bench/competition_dual_platform_demo.sh both plan

# 两侧只读探测
./bench/competition_dual_platform_demo.sh both preflight

# VM 版：真实 workload 需要先提供目标 VM IP 或外部流量命令
CONFIRM_LIVE=1 \
  VM_IFACES='br-int br-ex ens33' \
  OPENSTACK_TARGET_IP=<backend-vm-ip> GRPC_PORT=50051 \
  ./bench/competition_dual_platform_demo.sh vm live

# K8s 版：临时创建 evidence namespace，结束时默认删除
CONFIRM_LIVE=1 KUBECONFIG=\$KUBECONFIG \
  REQUESTS=20 WARMUP=5 DURATION=8 \
  ./bench/competition_dual_platform_demo.sh k8s live
```

每次运行的证据目录：

```
artifacts/competition-demo/<run-id>/
  vm/
  k8s/
  demo-card.md
  summary.md
```

当前默认不启动 Kubernetes 服务、不恢复 OpenStack 服务，也不自动 apply
`k8s/manifests`。集群服务恢复应按学校集群运维手册逐节点执行。
MD
}

run_vm() {
  CURRENT_PLATFORM="vm"
  remote_run_as_root=1
  local target_node="${vm_node}"
  CURRENT_OUT="${out_dir}/vm"
  mkdir -p "${CURRENT_OUT}"

  if [[ "${mode}" == "plan" ]]; then
    return 0
  fi

  run_target_script path-probe bench/openstack_path_probe.sh "${target_node}"

  if [[ "${mode}" == "preflight" ]]; then
    if [[ -n "${target_node}" ]]; then
      record_remote_command vm_host_state "${target_node}" \
        'hostname; uname -a; ip -br link; ip route; sudo -n tc qdisc show; sudo -n ovs-vsctl show; sudo -n virsh list --all'
    elif [[ "$(uname -s)" == "Linux" || "${RUN_LOCAL_HOST_PROBE:-0}" == "1" ]]; then
      record vm_local_state uname -a
      record vm_interfaces ip -br link
      record vm_routes ip route
      record vm_tc_state tc qdisc show
      if command -v ovs-vsctl >/dev/null 2>&1; then
        record vm_ovs_state run_sudo ovs-vsctl show
      else
        printf 'ovs-vsctl not found\n' >"${CURRENT_OUT}/vm_ovs_state.log"
        printf '127\n' >"${CURRENT_OUT}/vm_ovs_state.rc"
      fi
      if command -v virsh >/dev/null 2>&1; then
        record vm_libvirt_state run_sudo virsh list --all
      else
        printf 'virsh not found\n' >"${CURRENT_OUT}/vm_libvirt_state.log"
        printf '127\n' >"${CURRENT_OUT}/vm_libvirt_state.rc"
      fi
    else
      write_unavailable vm_host_state \
        "Skipped VM host inspection on $(uname -s) staging host. Set VM_NODE=node1 (or another Linux cluster node) for the real VM path."
    fi
    return 0
  fi

  # The tc smoke is short-lived and detaches on exit. It is useful even when
  # no real VM traffic command has been prepared yet.
  run_target_script tc-attach-smoke bench/openstack_tc_attach_smoke.sh "${target_node}" \
    "IFACES=${VM_IFACES:-br-int br-ex ens33}" \
    "DURATION=${VM_TC_DURATION:-5}" \
    "GRPC_PORT=${GRPC_PORT:-50051}"
  copy_named_summary tc-attach-smoke tc-attach-summary.md

  if [[ -n "${OPENSTACK_TARGET_IP:-}" || -n "${OPENSTACK_TRAFFIC_CMD:-}" ]]; then
    run_target_script workload-evidence bench/openstack_workload_evidence.sh "${target_node}" \
      "IFACE=${VM_IFACE:-}" \
      "IFACES=${VM_IFACES:-br-int br-ex ens33}" \
      "OPENSTACK_TARGET_IP=${OPENSTACK_TARGET_IP:-}" \
      "OPENSTACK_TRAFFIC_CMD=${OPENSTACK_TRAFFIC_CMD:-}" \
      "GRPC_PORT=${GRPC_PORT:-50051}" \
      "REQUESTS=${REQUESTS:-20}" \
      "WARMUP=${WARMUP:-5}" \
      "DURATION=${DURATION:-8}"
    copy_named_summary workload-evidence workload-summary.md
  else
    cat >"${CURRENT_OUT}/workload-skipped.md" <<'MD'
# VM workload skipped

No `OPENSTACK_TARGET_IP` or `OPENSTACK_TRAFFIC_CMD` was supplied. The VM
version still collected the attach-point smoke, but this run must not be
described as real VM-to-VM workload evidence.
MD
    printf 'skipped\n' >"${CURRENT_OUT}/workload_evidence.rc"
  fi

  # The full OpenStack TAP UDP benchmark is deliberately a separate opt-in:
  # it stops/restores the TAP adapter and requires the exact current VM/release
  # fixture. It is useful for the performance slide, not for the first smoke.
  if [[ "${VM_UDP_FASTPATH:-0}" == "1" && -n "${CLIENT_INSTANCE:-}" && -n "${BACKEND_INSTANCE:-}" && -n "${CLIENT_TAP:-}" && -n "${BACKEND_IP:-}" ]]; then
    record_shell udp_fastpath_benchmark \
      "OUT_DIR='${CURRENT_OUT}/udp-fastpath' CLIENT_INSTANCE='${CLIENT_INSTANCE}' BACKEND_INSTANCE='${BACKEND_INSTANCE}' CLIENT_TAP='${CLIENT_TAP}' BACKEND_IP='${BACKEND_IP}' bash '${repo_dir}/bench/openstack_udp_fastpath_bench.sh' '${VM_FASTPATH_PROFILE:-smoke}'"
    copy_named_summary udp-fastpath udp-fastpath-summary.md
  elif [[ "${VM_UDP_FASTPATH:-0}" == "1" ]]; then
    printf 'skipped: VM_UDP_FASTPATH=1 requires explicit CLIENT_INSTANCE, BACKEND_INSTANCE, CLIENT_TAP and BACKEND_IP\n' \
      >"${CURRENT_OUT}/udp_fastpath_benchmark.log"
    printf 'skipped\n' >"${CURRENT_OUT}/udp_fastpath_benchmark.rc"
  else
    printf 'not requested; use VM_UDP_FASTPATH=1 only after validating the current VM fixture\n' \
      >"${CURRENT_OUT}/udp_fastpath_benchmark.log"
    printf 'skipped\n' >"${CURRENT_OUT}/udp_fastpath_benchmark.rc"
  fi
}

run_k8s() {
  CURRENT_PLATFORM="k8s"
  remote_run_as_root=1
  local target_node="${k8s_node}"
  CURRENT_OUT="${out_dir}/k8s"
  mkdir -p "${CURRENT_OUT}"

  # Always point kubectl at the declared cluster, even when the file is
  # missing, so a user's unrelated default kubeconfig is never touched.
  export KUBECONFIG="${kubeconfig}"

  if [[ "${mode}" == "plan" ]]; then
    return 0
  fi

  run_target_script path-probe bench/k8s_path_probe.sh "${target_node}" \
    "KUBECONFIG=${K8S_REMOTE_KUBECONFIG:-/etc/kubernetes/admin.conf}"

  if [[ "${mode}" == "preflight" ]]; then
    if [[ -n "${target_node}" ]]; then
      record_remote_command k8s_host_state "${target_node}" \
        'hostname; uname -a; ip -br link; ip route; sudo -n tc qdisc show; sudo -n crictl pods; sudo -n systemctl is-active kubelet containerd kubernetes-haproxy'
    elif command -v kubectl >/dev/null 2>&1; then
      record k8s_kubeconfig test -r "${kubeconfig}"
      record k8s_nodes kubectl get nodes -o wide
      record k8s_pods kubectl get pods -A -o wide
      record k8s_readyz kubectl get --raw=/readyz
      record k8s_services kubectl get services -A -o wide
    else
      record k8s_kubeconfig test -r "${kubeconfig}"
      printf 'kubectl not found\n' >"${CURRENT_OUT}/k8s_nodes.log"
      printf '127\n' >"${CURRENT_OUT}/k8s_nodes.rc"
    fi
    return 0
  fi

  if [[ -n "${target_node}" ]]; then
    run_target_script workload-evidence bench/k8s_workload_evidence.sh "${target_node}" \
      "KUBECONFIG=${K8S_REMOTE_KUBECONFIG:-/etc/kubernetes/admin.conf}" \
      "REQUESTS=${REQUESTS:-20}" \
      "WARMUP=${WARMUP:-5}" \
      "DURATION=${DURATION:-8}" \
      "KEEP_RESOURCES=${KEEP_RESOURCES:-0}" \
      "NAMESPACE=${NAMESPACE:-ebpf-competition-demo}" \
      "K8S_WORKLOAD_IMAGE=${K8S_WORKLOAD_IMAGE:-nginx:alpine}" \
      "IFACE=${K8S_IFACE:-}" \
      "GRPC_IFACE=${K8S_GRPC_IFACE:-}" \
      "GRPC_MONITOR_PORT=${GRPC_MONITOR_PORT:-80}"
    copy_named_summary workload-evidence workload-summary.md
  elif [[ -r "${kubeconfig}" ]]; then
    run_target_script workload-evidence bench/k8s_workload_evidence.sh "" \
      "KUBECONFIG=${kubeconfig}" \
      "REQUESTS=${REQUESTS:-20}" \
      "WARMUP=${WARMUP:-5}" \
      "DURATION=${DURATION:-8}" \
      "KEEP_RESOURCES=${KEEP_RESOURCES:-0}" \
      "NAMESPACE=${NAMESPACE:-ebpf-competition-demo}" \
      "K8S_WORKLOAD_IMAGE=${K8S_WORKLOAD_IMAGE:-nginx:alpine}" \
      "IFACE=${K8S_IFACE:-}" \
      "GRPC_IFACE=${K8S_GRPC_IFACE:-}" \
      "GRPC_MONITOR_PORT=${GRPC_MONITOR_PORT:-80}"
    copy_named_summary workload-evidence workload-summary.md
  else
    cat >"${CURRENT_OUT}/workload-skipped.md" <<MD
# Kubernetes workload skipped

Kubeconfig is missing or unreadable: `${kubeconfig}`.
No Kubernetes resource was created by the dual-platform wrapper.
MD
    printf 'skipped\n' >"${CURRENT_OUT}/workload_evidence.rc"
  fi

  # Keep the integration slice visible in the evidence package without
  # applying it. Applying the privileged DaemonSet is a separate deployment
  # decision and requires Linux/amd64 images plus a validated CNI mapping.
  if command -v kubectl >/dev/null 2>&1; then
    record_shell manifest_render "kubectl kustomize '${repo_dir}/k8s/manifests'"
  fi
}

write_summary() {
  local vm_rc k8s_rc
  vm_rc="not-run"
  k8s_rc="not-run"
  if [[ "${platform}" == "vm" || "${platform}" == "both" ]]; then
    vm_rc="$(read_rc "${out_dir}/vm/path-probe.rc")"
  fi
  if [[ "${platform}" == "k8s" || "${platform}" == "both" ]]; then
    k8s_rc="$(read_rc "${out_dir}/k8s/path-probe.rc")"
  fi

  cat >"${out_dir}/summary.md" <<MD
# Linux Accel 双平台展示汇总

| 项目 | 值 |
| --- | --- |
| platform | ${platform} |
| mode | ${mode} |
| run_id | ${run_id} |
| VM path probe rc | ${vm_rc} |
| K8s path probe rc | ${k8s_rc} |
| K8s kubeconfig | ${kubeconfig} |

## 现场口径

- VM 版：OpenStack/OVS 的 \`br-int\`、TAP、veth 是真实挂载点；DNS 和确定性短 UDP 可以进入 generic XDP exact-hit，miss/非法/超时回到内核协议栈。
- K8s 版：CNI、Pod veth、Service 和 overlay 是真实路径；当前 live evidence 证明路径可见性和 DNS/TC 观测，不把它表述成 native NIC XDP。
- gRPC 和 LDAP：当前主要是 TC/用户态监控或代理路径，不宣称是 XDP 快路径。
- 旧的性能数字只作为“已验证历史结果”；只有本次目录内新生成的 summary 才可称为本次现场 live 结果。

## 证据目录

- \`demo-card.md\`
- \`vm/path-probe/summary.md\`
- \`vm/tc-attach-summary.md\`（live VM 运行时）
- \`vm/workload-summary.md\`（提供真实目标/流量时）
- \`vm/udp-fastpath-summary.md\`（显式设置 \`VM_UDP_FASTPATH=1\` 时）
- \`k8s/path-probe/summary.md\`
- \`k8s/workload-summary.md\`（live K8s 且 API 可达时）

## 当前环境状态

本入口遇到 API/SSH 不可达时仍会保存失败日志和 rc 文件，不会自动启动
Kubernetes、重启 OpenStack、apply 特权 DaemonSet 或删除非本次创建的资源。
MD
}

write_plan
case "${platform}" in
  vm) run_vm ;;
  k8s) run_k8s ;;
  both) run_vm; run_k8s ;;
esac
write_summary

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
