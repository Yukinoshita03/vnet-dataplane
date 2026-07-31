#!/usr/bin/env bash
set -euo pipefail
umask 077

accel_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_dir="$(cd "${accel_dir}/.." && pwd)"
out_dir="${OUT_DIR:?OUT_DIR is required}"

client_server_id="${CLIENT_SERVER_ID:?CLIENT_SERVER_ID is required}"
client_port_id="${CLIENT_PORT_ID:?CLIENT_PORT_ID is required}"
backend_server_id="${BACKEND_SERVER_ID:?BACKEND_SERVER_ID is required}"
backend_port_id="${BACKEND_PORT_ID:?BACKEND_PORT_ID is required}"
client_ip="${CLIENT_IP:?CLIENT_IP is required}"
backend_ip="${BACKEND_IP:?BACKEND_IP is required}"

requests="${REQUESTS:-40}"
warmup="${WARMUP:-10}"
convergence_windows="${CONVERGENCE_WINDOWS:-3}"
commit_timeout="${COMMIT_TIMEOUT:-45}"
expected_compute_host="${EXPECTED_COMPUTE_HOST:-master}"
compute2_host="${COMPUTE2_HOST:-compute2}"
client_guest_host="${CLIENT_GUEST_HOST:-client-guest}"
backend_guest_host="${BACKEND_GUEST_HOST:-backend-guest}"
action_driver="${VNET_E2E_ACTION_DRIVER:-}"
execution_mode="real"
[[ -z "${action_driver}" ]] || execution_mode="test_driver"
deploy_artifacts="${DEPLOY_ARTIFACTS:-1}"
require_netmig_tc="${REQUIRE_NETMIG_TC:-1}"
preflight_only="${PREFLIGHT_ONLY:-0}"
cleanup_audit_only="${CLEANUP_AUDIT_ONLY:-0}"
remote_command_timeout="${REMOTE_COMMAND_TIMEOUT:-30}"
probe_timeout="${PROBE_TIMEOUT:-5}"
deployment_timeout="${DEPLOYMENT_TIMEOUT:-60}"
attach_timeout="${ATTACH_TIMEOUT:-90}"

openstack_openrc="${OPENSTACK_OPENRC:-/opt/stack/devstack/openrc}"
openstack_openrc_user="${OPENSTACK_OPENRC_USER:-admin}"
openstack_openrc_project="${OPENSTACK_OPENRC_PROJECT:-admin}"
openstack_bin="${OPENSTACK_BIN:-openstack}"
python_bin="${PYTHON_BIN:-python3}"
ssh_bin="${SSH_BIN:-ssh}"
sudo_bin="${SUDO_BIN:-sudo}"
tar_bin="${TAR_BIN:-tar}"
timeout_bin="${TIMEOUT_BIN:-timeout}"
known_hosts="${VNET_KNOWN_HOSTS:-/etc/vnet-dataplane-agent/lab-known-hosts.p1}"

coordinator_script="${accel_dir}/agent/openstack_epoch_coordinator.py"
coordinator_config="/etc/vnet-dataplane-agent/coordinator.json"
desired_mode_file="/run/vnet-dataplane-metrics-controller/desired-mode.json"
coordinator_state_file="/var/lib/vnet-dataplane-epoch/state.json"
coordinator_audit_log="/var/log/vnet-dataplane-epoch/audit.jsonl"

coordinator_unit="vnet-dataplane-epoch-coordinator.service"
metrics_unit="vnet-dataplane-metrics-controller.service"
host_agent_unit="vnet-dataplane-agent.service"
guest_agent_unit="vnet-dataplane-guest-endpoint.service"
dns_backend_unit="vnet-lab-dns-backend.service"
grpc_backend_unit="vnet-lab-grpc-backend.service"

client_tap="tap${client_port_id:0:11}"
backend_tap="tap${backend_port_id:0:11}"
total_requests=$((requests + warmup))

run_status="failed"
cleanup_status=0
mutated=0
cleanup_started=0
coordinator_started=0
baseline_epoch=0
bypass_epoch=0
server_epoch=0
dns_backend_suppressed=false
experiment_executed=false

if [[ -e "${out_dir}" && ! -d "${out_dir}" ]]; then
  echo "OUT_DIR exists and is not a directory: ${out_dir}" >&2
  exit 2
fi
if [[ -d "${out_dir}" && -n "$(find "${out_dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "OUT_DIR must be new or empty: ${out_dir}" >&2
  exit 2
fi
mkdir -p "${out_dir}/raw" "${out_dir}/systemd" "${out_dir}/openstack"
exec 3>&1 4>&2
exec > >(tee "${out_dir}/run.log" >&3) 2>&1
run_log_pid=$!
run_log_closed=0

if [[ -z "${action_driver}" ]]; then
  (( EUID == 0 )) || {
    echo "real lab execution must run as root (use sudo env ... bash ${BASH_SOURCE[0]})" >&2
    exit 2
  }
  command -v flock >/dev/null || {
    echo "flock is required for real lab execution" >&2
    exit 2
  }
  exec {lab_lock_fd}>"${VNET_E2E_LOCK_PATH:-/tmp/vnet-openstack-systemd-e2e.lock}"
  flock -n "${lab_lock_fd}" || {
    echo "another OpenStack systemd E2E run owns the lab lock" >&2
    exit 1
  }
fi

for numeric_name in requests warmup convergence_windows; do
  numeric_value="${!numeric_name}"
  [[ "${numeric_value}" =~ ^[0-9]+$ ]] || {
    echo "${numeric_name} must be a non-negative integer" >&2
    exit 2
  }
done
(( requests > 0 && convergence_windows > 0 )) || {
  echo "REQUESTS and CONVERGENCE_WINDOWS must be positive" >&2
  exit 2
}
[[ "${commit_timeout}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "COMMIT_TIMEOUT must be positive" >&2
  exit 2
}
for timeout_name in remote_command_timeout probe_timeout deployment_timeout attach_timeout; do
  timeout_value="${!timeout_name}"
  [[ "${timeout_value}" =~ ^[1-9][0-9]*$ ]] || {
    echo "${timeout_name} must be a positive integer" >&2
    exit 2
  }
done
[[ "${deploy_artifacts}" == 0 || "${deploy_artifacts}" == 1 ]] || {
  echo "DEPLOY_ARTIFACTS must be 0 or 1" >&2
  exit 2
}
[[ "${require_netmig_tc}" == 0 || "${require_netmig_tc}" == 1 ]] || {
  echo "REQUIRE_NETMIG_TC must be 0 or 1" >&2
  exit 2
}
[[ "${preflight_only}" == 0 || "${preflight_only}" == 1 ]] || {
  echo "PREFLIGHT_ONLY must be 0 or 1" >&2
  exit 2
}
[[ "${cleanup_audit_only}" == 0 || "${cleanup_audit_only}" == 1 ]] || {
  echo "CLEANUP_AUDIT_ONLY must be 0 or 1" >&2
  exit 2
}
(( preflight_only + cleanup_audit_only <= 1 )) || {
  echo "PREFLIGHT_ONLY and CLEANUP_AUDIT_ONLY are mutually exclusive" >&2
  exit 2
}
[[ "${client_server_id}" != "${backend_server_id}" &&
   "${client_port_id}" != "${backend_port_id}" ]] || {
  echo "client and backend OpenStack identities must be distinct" >&2
  exit 2
}
for uuid_name in client_server_id client_port_id backend_server_id backend_port_id; do
  uuid_value="${!uuid_name}"
  [[ "${uuid_value}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
    echo "${uuid_name} must be a canonical lowercase UUID" >&2
    exit 2
  }
done
for host_name in expected_compute_host compute2_host client_guest_host backend_guest_host; do
  host_value="${!host_name}"
  [[ "${host_value}" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,254}$ ]] || {
    echo "${host_name} contains unsupported SSH hostname characters" >&2
    exit 2
  }
done
"${python_bin}" - "${client_ip}" "${backend_ip}" <<'PY'
import ipaddress
import sys

for value in sys.argv[1:]:
    address = ipaddress.ip_address(value)
    if address.version != 4 or not address.is_private:
        raise SystemExit(f"lab address must be a private IPv4 address: {value}")
PY

ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o HostKeyAlgorithms=ssh-ed25519
  -o ConnectTimeout=5
)

local_sudo() {
  "${sudo_bin}" -n "$@"
}

remote_exec() {
  local host="$1"
  shift
  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${ssh_bin}" -n "${ssh_options[@]}" "${host}" "$@"
}

remote_probe() {
  local host="$1"
  shift
  "${timeout_bin}" --signal=TERM "${probe_timeout}" \
    "${ssh_bin}" -n "${ssh_options[@]}" "${host}" "$@"
}

remote_sudo() {
  local host="$1"
  shift
  remote_exec "${host}" /usr/bin/sudo -n "$@"
}

remote_sudo_probe() {
  local host="$1"
  shift
  remote_probe "${host}" /usr/bin/sudo -n "$@"
}

systemctl_local() {
  local operation="$1"
  local unit="$2"
  if [[ "${operation}" == stop ]]; then
    local load_state
    load_state="$(local_sudo /usr/bin/systemctl show -p LoadState --value \
      "${unit}" 2>/dev/null)" || return 1
    if [[ "${load_state}" == not-found ]]; then
      return 0
    fi
    local_sudo /usr/bin/systemctl stop "${unit}" || return 1
    assert_unit_inactive_local "${unit}"
    return
  fi
  local_sudo /usr/bin/systemctl start "${unit}"
  local_sudo /usr/bin/systemctl is-active --quiet "${unit}"
}

systemctl_remote() {
  local host="$1"
  local operation="$2"
  local unit="$3"
  if [[ "${operation}" == stop ]]; then
    local load_state
    load_state="$(remote_sudo "${host}" /usr/bin/systemctl show \
      -p LoadState --value "${unit}" 2>/dev/null)" || return 1
    if [[ "${load_state}" == not-found ]]; then
      return 0
    fi
    remote_sudo "${host}" /usr/bin/systemctl stop "${unit}" || return 1
    assert_unit_inactive_remote "${host}" "${unit}"
    return
  fi
  remote_sudo "${host}" /usr/bin/systemctl start "${unit}"
  remote_sudo "${host}" /usr/bin/systemctl is-active --quiet "${unit}"
}

capture_openstack_evidence() {
  [[ -r "${openstack_openrc}" ]] || {
    echo "OPENSTACK_OPENRC is not readable: ${openstack_openrc}" >&2
    return 1
  }
  command -v "${openstack_bin}" >/dev/null
  command -v "${python_bin}" >/dev/null

  set +u
  # shellcheck source=/dev/null
  source "${openstack_openrc}" \
    "${openstack_openrc_user}" "${openstack_openrc_project}"
  set -u

  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${openstack_bin}" server show "${client_server_id}" -f json \
    >"${out_dir}/openstack/client-server.json"
  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${openstack_bin}" server show "${backend_server_id}" -f json \
    >"${out_dir}/openstack/backend-server.json"
  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${openstack_bin}" port show "${client_port_id}" -f json \
    >"${out_dir}/openstack/client-port.json"
  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${openstack_bin}" port show "${backend_port_id}" -f json \
    >"${out_dir}/openstack/backend-port.json"

  "${python_bin}" - \
    "${out_dir}/openstack/client-server.json" \
    "${out_dir}/openstack/backend-server.json" \
    "${out_dir}/openstack/client-port.json" \
    "${out_dir}/openstack/backend-port.json" \
    "${client_server_id}" "${backend_server_id}" \
    "${client_port_id}" "${backend_port_id}" \
    "${client_ip}" "${backend_ip}" \
    "${expected_compute_host}" \
    "${out_dir}/openstack/fingerprints.json" <<'PY'
import json
import re
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"OpenStack output is not an object: {path}")
    return value


def normalized(value):
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def field(value, *names):
    fields = {normalized(str(key)): item for key, item in value.items()}
    for name in names:
        if normalized(name) in fields:
            return fields[normalized(name)]
    raise SystemExit(f"missing OpenStack field: {names}")


client_server = load(sys.argv[1])
backend_server = load(sys.argv[2])
client_port = load(sys.argv[3])
backend_port = load(sys.argv[4])
(
    client_server_id,
    backend_server_id,
    client_port_id,
    backend_port_id,
    client_ip,
    backend_ip,
    expected_host,
) = sys.argv[5:12]
output = Path(sys.argv[12])

for name, server, expected_id in (
    ("client", client_server, client_server_id),
    ("backend", backend_server, backend_server_id),
):
    if str(field(server, "id")) != expected_id:
        raise SystemExit(f"{name} server show returned a mismatched ID")
    if str(field(server, "status")).upper() != "ACTIVE":
        raise SystemExit(f"{name} server is not ACTIVE")
    host = str(field(server, "OS-EXT-SRV-ATTR:host", "host"))
    if host != expected_host:
        raise SystemExit(f"{name} server is on {host}, expected {expected_host}")

fingerprints = {}
for name, port, server_id, port_id, expected_ip in (
    ("client", client_port, client_server_id, client_port_id, client_ip),
    ("backend", backend_port, backend_server_id, backend_port_id, backend_ip),
):
    if str(field(port, "id")) != port_id:
        raise SystemExit(f"{name} port show returned a mismatched ID")
    if str(field(port, "status")).upper() != "ACTIVE":
        raise SystemExit(f"{name} port is not ACTIVE")
    if str(field(port, "device_id")) != server_id:
        raise SystemExit(f"{name} port device_id does not match server")
    host = str(field(port, "binding_host_id", "binding:host_id"))
    if host != expected_host:
        raise SystemExit(f"{name} port is bound to {host}, expected {expected_host}")
    mac = str(field(port, "mac_address")).lower()
    if not re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", mac):
        raise SystemExit(f"{name} port has an invalid MAC address")
    fixed_ips = field(port, "fixed_ips")
    if expected_ip not in re.findall(
        r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])",
        json.dumps(fixed_ips, sort_keys=True),
    ):
        raise SystemExit(f"{name} port does not contain expected IP {expected_ip}")
    fingerprints[name] = {
        "server_id": server_id,
        "port_id": port_id,
        "host": host,
        "mac": mac,
        "ip": expected_ip,
    }

if fingerprints["client"]["mac"] == fingerprints["backend"]["mac"]:
    raise SystemExit("client and backend ports have the same MAC fingerprint")
output.write_text(
    json.dumps(fingerprints, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

validate_bundle_configuration() {
  "${python_bin}" - \
    "${accel_dir}/deploy/lab/shuka1-p1/endpoint-client.json" \
    "${accel_dir}/deploy/lab/shuka1-p1/endpoint-server.json" \
    "${accel_dir}/deploy/lab/shuka1-p1/coordinator.json" \
    "${accel_dir}/deploy/lab/shuka1-p1/metrics-bridge.json" \
    "${accel_dir}/deploy/lab/shuka1-p1/dns-cache.policy" \
    "${accel_dir}/deploy/lab/shuka1-p1/vnet-lab-dns-backend.service" \
    "${accel_dir}/deploy/lab/shuka1-p1/vnet-lab-grpc-backend.service" \
    "${client_server_id}" "${client_port_id}" \
    "${backend_server_id}" "${backend_port_id}" \
    "${client_ip}" "${backend_ip}" \
    "${client_guest_host}" "${backend_guest_host}" "${compute2_host}" \
    "${expected_compute_host}" <<'PY'
import json
import re
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"bundle JSON is not an object: {path}")
    return value


(
    client_endpoint_path,
    backend_endpoint_path,
    coordinator_path,
    metrics_path,
    dns_policy_path,
    dns_unit_path,
    grpc_unit_path,
    client_server_id,
    client_port_id,
    backend_server_id,
    backend_port_id,
    client_ip,
    backend_ip,
    client_host,
    backend_host,
    compute2_host,
    expected_compute_host,
) = sys.argv[1:]

client = load(client_endpoint_path)
backend = load(backend_endpoint_path)
coordinator = load(coordinator_path)
metrics = load(metrics_path)

expected = {
    "client": (client_server_id, client_port_id),
    "server": (backend_server_id, backend_port_id),
}
for name, endpoint in (("client", client), ("server", backend)):
    server_id, port_id = expected[name]
    if endpoint.get("server_id") != server_id or endpoint.get("port_id") != port_id:
        raise SystemExit(f"{name} endpoint identity does not match runner inputs")
    if endpoint.get("accel_role") != name:
        raise SystemExit(f"{name} endpoint has the wrong acceleration role")
    if endpoint.get("interface") != "ens3":
        raise SystemExit(f"{name} endpoint must target ens3")

if client.get("grpc", {}).get("backend") != f"{backend_ip}:50052":
    raise SystemExit("client endpoint gRPC backend does not match BACKEND_IP")
if backend.get("grpc", {}).get("backend") != f"{backend_ip}:50051":
    raise SystemExit("server endpoint gRPC backend does not match BACKEND_IP")

required = {
    (item.get("compute_role"), item.get("server_id"), item.get("port_id"))
    for item in coordinator.get("required_endpoints", [])
    if isinstance(item, dict)
}
expected_required = {
    ("client", client_server_id, client_port_id),
    ("observer", backend_server_id, backend_port_id),
}
if required != expected_required:
    raise SystemExit("coordinator required_endpoints do not match runner inputs")

allowed_pairs = {
    (client_server_id, client_port_id),
    (backend_server_id, backend_port_id),
}
publishers = coordinator.get("publishers", [])
if not isinstance(publishers, list) or any(
    not isinstance(item, dict) for item in publishers
):
    raise SystemExit("coordinator publishers are invalid")
publisher_by_name = {item.get("name"): item for item in publishers}
if len(publisher_by_name) != len(publishers):
    raise SystemExit("coordinator publisher names are duplicated")
publisher_pairs = {
    (item.get("server_id"), item.get("port_id")) for item in publishers
}
if publisher_pairs != allowed_pairs:
    raise SystemExit("coordinator publisher identities do not match runner inputs")

expected_publishers = {
    "master-client-caches": (
        client_server_id,
        client_port_id,
        expected_compute_host,
        "client-host-caches",
        "compute_port",
        "client",
        {"dns", "grpc"},
    ),
    "compute2-client-caches": (
        client_server_id,
        client_port_id,
        compute2_host,
        "client-host-caches",
        "compute_port",
        "client",
        {"dns", "grpc"},
    ),
    "client-guest-grpc": (
        client_server_id,
        client_port_id,
        client_host,
        "grpc-client-guest-cache",
        "guest_endpoint",
        "client",
        {"grpc"},
    ),
    "backend-host-caches": (
        backend_server_id,
        backend_port_id,
        expected_compute_host,
        "backend-host-caches",
        "guest_endpoint",
        "server",
        {"grpc"},
    ),
    "backend-guest-caches": (
        backend_server_id,
        backend_port_id,
        backend_host,
        "backend-guest-caches",
        "guest_endpoint",
        "server",
        {"dns", "grpc"},
    ),
}
if set(publisher_by_name) != set(expected_publishers):
    raise SystemExit("coordinator publisher set does not match the lab")
for name, expected_values in expected_publishers.items():
    publisher = publisher_by_name[name]
    actual_values = (
        publisher.get("server_id"),
        publisher.get("port_id"),
        publisher.get("host"),
        publisher.get("actor_id"),
        publisher.get("target_kind"),
        publisher.get("cache_role"),
        set(publisher.get("services", [])),
    )
    if actual_values != expected_values:
        raise SystemExit(f"coordinator publisher is stale or misbound: {name}")
    command_text = json.dumps(publisher.get("command", []), sort_keys=True)
    if publisher["port_id"] not in command_text or "cache_policy_txn" not in command_text:
        raise SystemExit(f"coordinator publisher command is misbound: {name}")

sources = metrics.get("sources", [])
if not isinstance(sources, list) or any(not isinstance(item, dict) for item in sources):
    raise SystemExit("metrics sources are invalid")
source_by_name = {item.get("name"): item for item in sources}
if len(source_by_name) != len(sources):
    raise SystemExit("metrics source names are duplicated")
expected_sources = {
    "master-dns-client-monitor": ("dns_metrics", "client", client_port_id, None),
    "compute2-dns-client-monitor": ("dns_metrics", "client", client_port_id, compute2_host),
    "backend-dns-guest-monitor": ("dns_metrics", "server", backend_port_id, backend_host),
    "master-grpc-client-monitor": ("grpc_metrics", "client", client_port_id, None),
    "compute2-grpc-client-monitor": ("grpc_metrics", "client", client_port_id, compute2_host),
    "master-grpc-observer-monitor": ("grpc_metrics", "server", backend_port_id, None),
    "client-guest-grpc-cache": ("grpc_fast_cache", "client", client_port_id, client_host),
    "backend-guest-grpc-cache": ("grpc_fast_cache", "server", backend_port_id, backend_host),
}
if set(source_by_name) != set(expected_sources):
    raise SystemExit("metrics source set does not match the lab")
for name, (kind, role, port_id, host) in expected_sources.items():
    source = source_by_name[name]
    if source.get("kind") != kind or source.get("role") != role:
        raise SystemExit(f"metrics source kind/role is stale: {name}")
    source_text = json.dumps(source, sort_keys=True)
    if port_id not in source_text or (host is not None and host not in source_text):
        raise SystemExit(f"metrics source path/host is stale: {name}")

documents = json.dumps(
    {"coordinator": coordinator, "metrics": metrics}, sort_keys=True
)
for identity in (
    client_server_id,
    client_port_id,
    backend_server_id,
    backend_port_id,
    client_host,
    backend_host,
    compute2_host,
):
    if identity not in documents:
        raise SystemExit(f"bundle does not reference required identity: {identity}")
known_uuids = set(
    re.findall(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        documents,
    )
)
if known_uuids - {
    client_server_id,
    client_port_id,
    backend_server_id,
    backend_port_id,
}:
    raise SystemExit("bundle contains an unexpected OpenStack UUID")

dns_policy = Path(dns_policy_path).read_text(encoding="utf-8")
if not re.search(
    rf"(?m)^dynamic[.]test[ \t]+{re.escape(backend_ip)}[ \t]+[0-9]+[ \t]*$",
    dns_policy,
):
    raise SystemExit("DNS cache policy does not match BACKEND_IP")
dns_unit = Path(dns_unit_path).read_text(encoding="utf-8")
grpc_unit = Path(grpc_unit_path).read_text(encoding="utf-8")
if f" server {backend_ip} 53 dynamic.test {backend_ip} " not in dns_unit:
    raise SystemExit("DNS backend unit does not match BACKEND_IP")
if f" server {backend_ip} 50051 " not in grpc_unit:
    raise SystemExit("gRPC backend unit does not match BACKEND_IP")
if client_ip == backend_ip:
    raise SystemExit("client and backend IP addresses must be distinct")
PY
}

required_deployment_files() {
  printf '%s\n' \
    "${coordinator_script}" \
    "${accel_dir}/agent/openstack_dataplane_agent.py" \
    "${accel_dir}/agent/openstack_epoch_gate.py" \
    "${accel_dir}/agent/openstack_guest_endpoint_agent.py" \
    "${accel_dir}/agent/openstack_metrics_bridge.py" \
    "${accel_dir}/build/cache_policy_txn" \
    "${accel_dir}/build/dns_client_cache.bpf.o" \
    "${accel_dir}/build/dns_monitor" \
    "${accel_dir}/build/dns_monitor.bpf.o" \
    "${accel_dir}/build/dns_cache_stats_reader" \
    "${accel_dir}/build/dns_xdp_monitor.bpf.o" \
    "${accel_dir}/build/grpc_monitor" \
    "${accel_dir}/build/grpc_monitor.bpf.o" \
    "${accel_dir}/build/grpc_fast_cache" \
    "${accel_dir}/build/openstack_dns_harness" \
    "${accel_dir}/build/openstack_grpc_harness" \
    "${accel_dir}/build/dynamic_cache_controller" \
    "${accel_dir}/deploy/lab/shuka1-p1/coordinator.env" \
    "${accel_dir}/deploy/lab/shuka1-p1/coordinator.json" \
    "${accel_dir}/deploy/lab/shuka1-p1/metrics-bridge.env" \
    "${accel_dir}/deploy/lab/shuka1-p1/metrics-bridge.json" \
    "${accel_dir}/deploy/lab/shuka1-p1/dns-cache.policy" \
    "${accel_dir}/deploy/lab/shuka1-p1/endpoint-client.json" \
    "${accel_dir}/deploy/lab/shuka1-p1/endpoint-server.json" \
    "${accel_dir}/deploy/lab/shuka1-p1/grpc-cache.policy" \
    "${accel_dir}/deploy/lab/shuka1-p1/guest-endpoint.env" \
    "${accel_dir}/deploy/lab/shuka1-p1/vnet-dataplane.sudoers" \
    "${accel_dir}/deploy/lab/shuka1-p1/vnet-lab-dns-backend.service" \
    "${accel_dir}/deploy/lab/shuka1-p1/vnet-lab-grpc-backend.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-bpffs.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-agent.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-guest-endpoint.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-metrics-controller.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-epoch-coordinator.service"
}

validate_deployment_inputs() {
  [[ "$(readlink -f "${repo_dir}")" == /opt/vnet-dataplane ]] || {
    echo "real lab deployment must run from /opt/vnet-dataplane" >&2
    return 1
  }
  local command path host
  local required_paths=()
  for command in flock "${openstack_bin}" "${python_bin}" "${ssh_bin}" \
    "${sudo_bin}" "${tar_bin}" "${timeout_bin}"; do
    command -v "${command}" >/dev/null || {
      echo "required command is missing: ${command}" >&2
      return 1
    }
  done
  while IFS= read -r path; do
    [[ -e "${path}" ]] || {
      echo "required deployment artifact is missing: ${path}" >&2
      return 1
    }
  done < <(required_deployment_files)
  mapfile -t required_paths < <(required_deployment_files)
  "${python_bin}" - "${repo_dir}" "${required_paths[@]}" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).absolute()
for raw in sys.argv[2:]:
    path = Path(raw).absolute()
    try:
        path.relative_to(root)
    except ValueError:
        raise SystemExit(f"deployment input escapes repository: {path}") from None
    current = path
    while True:
        status = os.lstat(current)
        if stat.S_ISLNK(status.st_mode):
            raise SystemExit(f"deployment input has a symlink component: {current}")
        if current == root:
            break
        current = current.parent
    status = os.lstat(path)
    if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
        raise SystemExit(f"deployment input is not a single-link regular file: {path}")
PY
  for path in \
    "${accel_dir}/build/cache_policy_txn" \
    "${accel_dir}/build/dns_monitor" \
    "${accel_dir}/build/dns_cache_stats_reader" \
    "${accel_dir}/build/grpc_monitor" \
    "${accel_dir}/build/grpc_fast_cache" \
    "${accel_dir}/build/openstack_dns_harness" \
    "${accel_dir}/build/openstack_grpc_harness" \
    "${accel_dir}/build/dynamic_cache_controller"; do
    [[ -x "${path}" ]] || {
      echo "required deployment executable is not executable: ${path}" >&2
      return 1
    }
  done
  local_sudo /usr/bin/true
  local_sudo /usr/bin/test -r "${known_hosts}"
  local_sudo /usr/sbin/visudo -cf \
    "${accel_dir}/deploy/lab/shuka1-p1/vnet-dataplane.sudoers"
  for host in "${compute2_host}" "${client_guest_host}" "${backend_guest_host}"; do
    remote_exec "${host}" /usr/bin/true
    remote_sudo "${host}" /usr/bin/true
    remote_sudo "${host}" /usr/bin/test -x /usr/bin/install
    remote_sudo "${host}" /usr/bin/test -x /usr/bin/systemctl
    if [[ "${deploy_artifacts}" == 1 ]]; then
      remote_sudo "${host}" /usr/bin/test -x /usr/bin/tar
    fi
    for path in \
      /opt \
      /opt/vnet-dataplane \
      /opt/vnet-dataplane/linux_accel \
      /opt/vnet-dataplane/linux_accel/agent \
      /opt/vnet-dataplane/linux_accel/build \
      /opt/vnet-dataplane/linux_accel/deploy \
      /opt/vnet-dataplane/linux_accel/deploy/lab \
      /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1 \
      /opt/vnet-dataplane/linux_accel/deploy/systemd; do
      remote_sudo "${host}" /usr/bin/test ! -L "${path}"
    done
  done
  local_sudo /usr/bin/cat /etc/vnet-dataplane-agent/endpoints.json \
    >"${out_dir}/openstack/master-endpoints.json"
  remote_sudo "${compute2_host}" /usr/bin/cat \
    /etc/vnet-dataplane-agent/endpoints.json \
    >"${out_dir}/openstack/compute2-endpoints.json"
  "${python_bin}" - \
    "${out_dir}/openstack/master-endpoints.json" \
    "${out_dir}/openstack/compute2-endpoints.json" \
    "${client_server_id}" "${backend_server_id}" "${backend_ip}" <<'PY'
import json
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("endpoints"), list):
        raise SystemExit(f"invalid compute endpoint config: {path}")
    return value


master = load(sys.argv[1])
compute2 = load(sys.argv[2])
client_server_id, backend_server_id, backend_ip = sys.argv[3:]
if master != compute2:
    raise SystemExit("master and compute2 endpoint configs differ")
if len(master["endpoints"]) != 2:
    raise SystemExit("compute endpoint config must contain exactly two endpoints")
endpoints = {
    item.get("server_id"): item
    for item in master["endpoints"]
    if isinstance(item, dict)
}
if len(endpoints) != len(master["endpoints"]):
    raise SystemExit("compute endpoint config contains duplicate server IDs")
if set(endpoints) != {client_server_id, backend_server_id}:
    raise SystemExit("compute endpoint config identities do not match runner inputs")
client = endpoints[client_server_id]
backend = endpoints[backend_server_id]
if client.get("accel_role") != "client" or backend.get("accel_role") != "observer":
    raise SystemExit("compute endpoint acceleration roles do not match the lab")
if backend_ip not in client.get("trusted_dns", []):
    raise SystemExit("client endpoint does not trust BACKEND_IP for DNS")
if client.get("grpc_observe_port") != 50052 or backend.get("grpc_observe_port") != 50052:
    raise SystemExit("compute endpoint gRPC observation ports do not match the lab")
if client.get("guest_grpc_listen_port") != 50053 or backend.get("guest_grpc_listen_port") != 50052:
    raise SystemExit("compute endpoint guest gRPC listen ports do not match the lab")
PY
  validate_bundle_configuration
  if [[ "${deploy_artifacts}" == 0 ]]; then
    local_sudo /usr/bin/test -r /etc/vnet-dataplane-agent/coordinator.json
    local_sudo /usr/bin/test -r \
      /etc/vnet-dataplane-metrics-controller/metrics-bridge.json
    remote_sudo "${compute2_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/cache_policy_txn
    remote_sudo "${client_guest_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/openstack_grpc_harness
    remote_sudo "${backend_guest_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/dns_monitor
  fi
}

capture_tc_identity() {
  local tap="$1"
  local direction="$2"
  local handle="$3"
  local output="$4"
  local raw="${output%.json}.txt"
  local_sudo /usr/sbin/tc filter show dev "${tap}" "${direction}" >"${raw}"
  "${python_bin}" - "${raw}" "${handle}" "${output}" <<'PY'
import json
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
handle = sys.argv[2]
output = Path(sys.argv[3])
lines = [line.strip() for line in source.read_text(encoding="utf-8").splitlines()]
matches = [line for line in lines if f"handle {handle} " in f"{line} "]
if len(matches) != 1:
    raise SystemExit(f"expected one TC filter for {handle}, found {len(matches)}")
program_id = re.search(r"(?:^| )id ([0-9]+)(?: |$)", matches[0])
tag = re.search(r"(?:^| )tag ([0-9a-f]+)(?: |$)", matches[0])
if program_id is None or tag is None:
    raise SystemExit(f"TC filter {handle} has no stable program ID/tag")
output.write_text(
    json.dumps(
        {"handle": handle, "program_id": int(program_id.group(1)), "tag": tag.group(1)},
        sort_keys=True,
        separators=(",", ":"),
    )
    + "\n",
    encoding="utf-8",
)
PY
}

capture_netmig_baseline() {
  [[ "${require_netmig_tc}" == 1 ]] || return 0
  capture_tc_identity "${client_tap}" ingress 0x65 \
    "${out_dir}/systemd/${client_tap}.netmig-ingress-before.json"
  capture_tc_identity "${client_tap}" egress 0x66 \
    "${out_dir}/systemd/${client_tap}.netmig-egress-before.json"
  capture_tc_identity "${backend_tap}" ingress 0x65 \
    "${out_dir}/systemd/${backend_tap}.netmig-ingress-before.json"
  capture_tc_identity "${backend_tap}" egress 0x66 \
    "${out_dir}/systemd/${backend_tap}.netmig-egress-before.json"
}

bind_compute_config_to_fingerprints() {
  "${python_bin}" - \
    "${out_dir}/openstack/master-endpoints.json" \
    "${out_dir}/openstack/fingerprints.json" \
    "${out_dir}/openstack/validated-endpoint-bindings.json" <<'PY'
import json
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"binding input is invalid: {path}")
    return value


config = load(sys.argv[1])
fingerprints = load(sys.argv[2])
output = Path(sys.argv[3])
configured = {
    item.get("server_id"): item.get("accel_role")
    for item in config.get("endpoints", [])
    if isinstance(item, dict)
}
expected = {
    fingerprints["client"]["server_id"]: "client",
    fingerprints["backend"]["server_id"]: "observer",
}
if configured != expected:
    raise SystemExit("compute config cannot be bound to the selected Neutron ports")
bindings = []
for role in ("client", "backend"):
    fingerprint = fingerprints[role]
    bindings.append(
        {
            "role": role,
            "accel_role": configured[fingerprint["server_id"]],
            **fingerprint,
        }
    )
output.write_text(
    json.dumps(
        {"schema_version": 1, "bindings": bindings},
        sort_keys=True,
        separators=(",", ":"),
    )
    + "\n",
    encoding="utf-8",
)
PY
}

preflight() {
  validate_deployment_inputs
  capture_openstack_evidence
  bind_compute_config_to_fingerprints
  capture_netmig_baseline
}

recheck_openstack_fingerprints() {
  local phase="${1:-attach}"
  local suffix report
  case "${phase}" in
    attach)
      suffix="after-attach"
      report="${out_dir}/openstack/fingerprint-recheck.json"
      ;;
    cleanup)
      suffix="after-cleanup"
      report="${out_dir}/openstack/fingerprint-recheck-after-cleanup.json"
      ;;
    *)
      echo "unknown OpenStack fingerprint recheck phase: ${phase}" >&2
      return 2
      ;;
  esac
  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${openstack_bin}" port show "${client_port_id}" -f json \
    >"${out_dir}/openstack/client-port-${suffix}.json" || return 1
  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${openstack_bin}" port show "${backend_port_id}" -f json \
    >"${out_dir}/openstack/backend-port-${suffix}.json" || return 1
  "${python_bin}" - \
    "${out_dir}/openstack/fingerprints.json" \
    "${out_dir}/openstack/client-port-${suffix}.json" \
    "${out_dir}/openstack/backend-port-${suffix}.json" \
    "${report}" "${phase}" <<'PY' || return 1
import json
import re
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"OpenStack fingerprint input is invalid: {path}")
    return value


def normalized(value):
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def field(value, name):
    fields = {normalized(str(key)): item for key, item in value.items()}
    try:
        return fields[normalized(name)]
    except KeyError:
        raise SystemExit(f"rechecked OpenStack port lacks {name}") from None


fingerprints = load(sys.argv[1])
ports = {"client": load(sys.argv[2]), "backend": load(sys.argv[3])}
output = Path(sys.argv[4])
phase = sys.argv[5]
records = {}
for role, port in ports.items():
    expected = fingerprints[role]
    actual = {
        "port_id": str(field(port, "id")),
        "server_id": str(field(port, "device_id")),
        "host": str(field(port, "binding_host_id")),
        "mac": str(field(port, "mac_address")).lower(),
        "status": str(field(port, "status")).upper(),
    }
    fixed_ips = json.dumps(field(port, "fixed_ips"), sort_keys=True)
    ipv4 = sorted(set(re.findall(
        r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])", fixed_ips
    )))
    expected_identity = {
        "port_id": expected["port_id"],
        "server_id": expected["server_id"],
        "host": expected["host"],
        "mac": expected["mac"],
        "status": "ACTIVE",
    }
    checks = {
        "identity_stable": actual == expected_identity,
        "status_active": actual["status"] == "ACTIVE",
        "fixed_ip_present": expected["ip"] in ipv4,
    }
    records[role] = {
        "expected": {**expected_identity, "ip": expected["ip"]},
        "actual": {**actual, "fixed_ipv4": ipv4},
        "checks": checks,
        "stable": all(checks.values()),
    }
result = {
    "schema_version": 1,
    "phase": phase,
    "stable": all(record["stable"] for record in records.values()),
    "ports": records,
}
output.write_text(
    json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
if not result["stable"]:
    raise SystemExit(f"Neutron identity changed during {phase} fingerprint recheck")
PY
}

verify_secure_stat_output() {
  local expected_count="$1"
  local output="$2"
  local count=0 uid mode file_type path
  while IFS=: read -r uid mode file_type path; do
    [[ -n "${uid}" ]] || continue
    count=$((count + 1))
    [[ "${uid}" == 0 && "${file_type}" == "regular file" ]] || return 1
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${mode} & 8#022) == 0 )) || return 1
    [[ -n "${path}" ]] || return 1
  done <<<"${output}"
  [[ "${count}" == "${expected_count}" ]]
}

verify_remote_secure_files() {
  local host="$1"
  shift
  local output
  output="$(remote_sudo "${host}" /usr/bin/stat \
    --format=%u:%a:%F:%n "$@")" || return 1
  verify_secure_stat_output "$#" "${output}"
}

verify_local_secure_files() {
  local output
  output="$(local_sudo /usr/bin/stat --format=%u:%a:%F:%n "$@")" || return 1
  verify_secure_stat_output "$#" "${output}"
}

stream_tree() {
  local host="$1"
  shift
  remote_sudo "${host}" /usr/bin/install -d -o root -g root -m 0755 \
    /opt/vnet-dataplane \
    /opt/vnet-dataplane/linux_accel \
    /opt/vnet-dataplane/linux_accel/agent \
    /opt/vnet-dataplane/linux_accel/build \
    /opt/vnet-dataplane/linux_accel/deploy \
    /opt/vnet-dataplane/linux_accel/deploy/lab \
    /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1 \
    /opt/vnet-dataplane/linux_accel/deploy/systemd
  (
    cd "${repo_dir}"
    "${tar_bin}" -cf - "$@"
  ) | "${timeout_bin}" --signal=TERM "${deployment_timeout}" \
    "${ssh_bin}" "${ssh_options[@]}" "${host}" \
    /usr/bin/sudo -n /usr/bin/tar --no-same-owner --no-same-permissions \
      -C /opt/vnet-dataplane -xf -
  local remote_paths=()
  local path
  for path in "$@"; do
    remote_paths+=("/opt/vnet-dataplane/${path}")
  done
  remote_sudo "${host}" /usr/bin/chown root:root "${remote_paths[@]}"
  remote_sudo "${host}" /usr/bin/chmod go-w "${remote_paths[@]}"
  verify_remote_secure_files "${host}" "${remote_paths[@]}"
}

secure_local_runtime_tree() {
  local files=()
  local path
  mapfile -t files < <(required_deployment_files)
  local_sudo /usr/bin/chown root:root \
    "${repo_dir}" "${accel_dir}" "${accel_dir}/agent" \
    "${accel_dir}/build" "${accel_dir}/deploy" \
    "${accel_dir}/deploy/lab" "${accel_dir}/deploy/lab/shuka1-p1" \
    "${accel_dir}/deploy/systemd"
  local_sudo /usr/bin/chmod 0755 \
    "${repo_dir}" "${accel_dir}" "${accel_dir}/agent" \
    "${accel_dir}/build" "${accel_dir}/deploy" \
    "${accel_dir}/deploy/lab" "${accel_dir}/deploy/lab/shuka1-p1" \
    "${accel_dir}/deploy/systemd"
  local_sudo /usr/bin/chown root:root "${files[@]}"
  local_sudo /usr/bin/chmod go-w "${files[@]}"
  verify_local_secure_files "${files[@]}"
}

install_local_deployment() {
  secure_local_runtime_tree
  local_sudo /usr/bin/install -m 0644 \
    "${accel_dir}/deploy/systemd/vnet-dataplane-bpffs.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-agent.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-metrics-controller.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-epoch-coordinator.service" \
    /etc/systemd/system/
  local_sudo /usr/bin/install -d -o root -g root -m 0700 \
    /etc/vnet-dataplane-agent /etc/vnet-dataplane-metrics-controller
  local_sudo /usr/bin/install -m 0600 \
    "${accel_dir}/deploy/lab/shuka1-p1/coordinator.env" \
    "${accel_dir}/deploy/lab/shuka1-p1/coordinator.json" \
    /etc/vnet-dataplane-agent/
  local_sudo /usr/bin/install -m 0600 \
    "${accel_dir}/deploy/lab/shuka1-p1/metrics-bridge.env" \
    "${accel_dir}/deploy/lab/shuka1-p1/metrics-bridge.json" \
    /etc/vnet-dataplane-metrics-controller/
  for required in openstack.env agent.env endpoints.json; do
    local_sudo /usr/bin/test -r "/etc/vnet-dataplane-agent/${required}"
  done
  local_sudo /usr/bin/test -r "${known_hosts}"
  local_sudo /usr/bin/systemctl daemon-reload
}

install_compute2_deployment() {
  local files=(
    linux_accel/agent/openstack_dataplane_agent.py
    linux_accel/agent/openstack_metrics_bridge.py
    linux_accel/build/cache_policy_txn
    linux_accel/build/dns_client_cache.bpf.o
    linux_accel/build/dns_monitor
    linux_accel/build/dns_monitor.bpf.o
    linux_accel/build/grpc_monitor
    linux_accel/build/grpc_monitor.bpf.o
    linux_accel/deploy/systemd/vnet-dataplane-agent.service
    linux_accel/deploy/systemd/vnet-dataplane-bpffs.service
  )
  stream_tree "${compute2_host}" "${files[@]}"
  remote_sudo "${compute2_host}" /usr/bin/install -m 0644 \
    /opt/vnet-dataplane/linux_accel/deploy/systemd/vnet-dataplane-agent.service \
    /opt/vnet-dataplane/linux_accel/deploy/systemd/vnet-dataplane-bpffs.service \
    /etc/systemd/system/
  for required in openstack.env agent.env endpoints.json; do
    remote_sudo "${compute2_host}" /usr/bin/test -r \
      "/etc/vnet-dataplane-agent/${required}"
  done
  remote_sudo "${compute2_host}" /usr/bin/systemctl daemon-reload
}

install_guest_deployment() {
  local host="$1"
  local endpoint_file="$2"
  local install_backend_units="$3"
  local files=(
    linux_accel/agent/openstack_guest_endpoint_agent.py
    linux_accel/agent/openstack_metrics_bridge.py
    linux_accel/build/cache_policy_txn
    linux_accel/build/dns_cache_stats_reader
    linux_accel/build/dns_monitor
    linux_accel/build/dns_xdp_monitor.bpf.o
    linux_accel/build/grpc_fast_cache
    linux_accel/build/openstack_dns_harness
    linux_accel/build/openstack_grpc_harness
    linux_accel/deploy/lab/shuka1-p1/dns-cache.policy
    linux_accel/deploy/lab/shuka1-p1/grpc-cache.policy
    linux_accel/deploy/lab/shuka1-p1/guest-endpoint.env
    "linux_accel/deploy/lab/shuka1-p1/${endpoint_file}"
    linux_accel/deploy/lab/shuka1-p1/vnet-dataplane.sudoers
    linux_accel/deploy/systemd/vnet-dataplane-bpffs.service
    linux_accel/deploy/systemd/vnet-dataplane-guest-endpoint.service
  )
  if [[ "${install_backend_units}" == 1 ]]; then
    files+=(
      linux_accel/deploy/lab/shuka1-p1/vnet-lab-dns-backend.service
      linux_accel/deploy/lab/shuka1-p1/vnet-lab-grpc-backend.service
    )
  fi
  stream_tree "${host}" "${files[@]}"
  remote_sudo "${host}" /usr/bin/install -d -o root -g root -m 0700 \
    /etc/vnet-dataplane-guest
  remote_sudo "${host}" /usr/bin/install -m 0600 \
    /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1/guest-endpoint.env \
    /etc/vnet-dataplane-guest/guest-endpoint.env
  remote_sudo "${host}" /usr/bin/install -m 0600 \
    "/opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1/${endpoint_file}" \
    /etc/vnet-dataplane-guest/endpoint.json
  remote_sudo "${host}" /usr/bin/install -m 0644 \
    /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1/dns-cache.policy \
    /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1/grpc-cache.policy \
    /etc/vnet-dataplane-guest/
  remote_sudo "${host}" /usr/bin/install -m 0644 \
    /opt/vnet-dataplane/linux_accel/deploy/systemd/vnet-dataplane-bpffs.service \
    /opt/vnet-dataplane/linux_accel/deploy/systemd/vnet-dataplane-guest-endpoint.service \
    /etc/systemd/system/
  remote_sudo "${host}" /usr/sbin/visudo -cf \
    /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1/vnet-dataplane.sudoers
  remote_sudo "${host}" /usr/bin/install -o root -g root -m 0440 \
    /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1/vnet-dataplane.sudoers \
    /etc/sudoers.d/vnet-dataplane
  remote_sudo "${host}" /usr/sbin/visudo -cf \
    /etc/sudoers.d/vnet-dataplane
  if [[ "${install_backend_units}" == 1 ]]; then
    remote_sudo "${host}" /usr/bin/install -m 0644 \
      /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1/vnet-lab-dns-backend.service \
      /opt/vnet-dataplane/linux_accel/deploy/lab/shuka1-p1/vnet-lab-grpc-backend.service \
      /etc/systemd/system/
  fi
  remote_sudo "${host}" /usr/bin/systemctl daemon-reload
}

deploy_or_verify() {
  if [[ "$(readlink -f "${repo_dir}")" != /opt/vnet-dataplane ]]; then
    echo "real lab deployment must run from /opt/vnet-dataplane" >&2
    return 1
  fi
  local required_local=(
    "${coordinator_script}"
    "${accel_dir}/agent/openstack_dataplane_agent.py"
    "${accel_dir}/agent/openstack_guest_endpoint_agent.py"
    "${accel_dir}/agent/openstack_metrics_bridge.py"
    "${accel_dir}/build/cache_policy_txn"
    "${accel_dir}/build/dns_monitor"
    "${accel_dir}/build/dns_cache_stats_reader"
    "${accel_dir}/build/grpc_monitor"
    "${accel_dir}/build/grpc_fast_cache"
    "${accel_dir}/build/openstack_dns_harness"
    "${accel_dir}/build/openstack_grpc_harness"
  )
  local path
  for path in "${required_local[@]}"; do
    [[ -e "${path}" ]] || {
      echo "required deployment artifact is missing: ${path}" >&2
      return 1
    }
  done
  if [[ "${deploy_artifacts}" == 1 ]]; then
    install_local_deployment
    install_compute2_deployment
    install_guest_deployment "${client_guest_host}" endpoint-client.json 0
    install_guest_deployment "${backend_guest_host}" endpoint-server.json 1
  else
    local_sudo /usr/bin/test -r /etc/vnet-dataplane-agent/coordinator.json
    local_sudo /usr/bin/test -r /etc/vnet-dataplane-metrics-controller/metrics-bridge.json
    remote_sudo "${compute2_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/cache_policy_txn
    remote_sudo "${client_guest_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/openstack_grpc_harness
    remote_sudo "${backend_guest_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/dns_monitor
  fi
}

capture_running_stack_evidence() {
  local_sudo /usr/bin/python3 \
    /opt/vnet-dataplane/linux_accel/agent/openstack_dataplane_agent.py health \
    --state-file /run/vnet-dataplane-agent/state.json \
    --server-id "${client_server_id}" --server-id "${backend_server_id}" \
    --max-age-seconds 20 \
    >"${out_dir}/systemd/master-agent-health.json" || return 1
  remote_sudo "${client_guest_host}" /usr/bin/python3 \
    /opt/vnet-dataplane/linux_accel/agent/openstack_guest_endpoint_agent.py health \
    --config /etc/vnet-dataplane-guest/endpoint.json \
    --state-file /run/vnet-dataplane-guest/state.json --max-age-seconds 20 \
    >"${out_dir}/systemd/client-guest-health.json" || return 1
  remote_sudo "${backend_guest_host}" /usr/bin/python3 \
    /opt/vnet-dataplane/linux_accel/agent/openstack_guest_endpoint_agent.py health \
    --config /etc/vnet-dataplane-guest/endpoint.json \
    --state-file /run/vnet-dataplane-guest/state.json --max-age-seconds 20 \
    >"${out_dir}/systemd/backend-guest-health.json" || return 1
  local_sudo /usr/bin/cat /run/vnet-dataplane-agent/state.json \
    >"${out_dir}/systemd/master-agent-state.json" || return 1
  remote_sudo "${compute2_host}" /usr/bin/cat \
    /run/vnet-dataplane-agent/state.json \
    >"${out_dir}/systemd/compute2-agent-state.json" || return 1
  remote_sudo "${client_guest_host}" /usr/bin/cat \
    /run/vnet-dataplane-guest/state.json \
    >"${out_dir}/systemd/client-guest-state.json" || return 1
  remote_sudo "${backend_guest_host}" /usr/bin/cat \
    /run/vnet-dataplane-guest/state.json \
    >"${out_dir}/systemd/backend-guest-state.json" || return 1
  remote_sudo "${client_guest_host}" /usr/sbin/ip -j address show dev ens3 \
    >"${out_dir}/systemd/client-guest-ens3.json" || return 1
  remote_sudo "${backend_guest_host}" /usr/sbin/ip -j address show dev ens3 \
    >"${out_dir}/systemd/backend-guest-ens3.json" || return 1
  local_sudo /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}/dns/cache_runtime_control" \
    >"${out_dir}/systemd/master-client-dns-runtime-map.json" || return 1
  local_sudo /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}/grpc/cache_runtime_control" \
    >"${out_dir}/systemd/master-client-grpc-runtime-map.json" || return 1
  local_sudo /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}/grpc/cache_runtime_control" \
    >"${out_dir}/systemd/master-backend-grpc-runtime-map.json" || return 1
  remote_sudo "${client_guest_host}" /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-guest/${client_port_id}/grpc/cache_runtime_control" \
    >"${out_dir}/systemd/client-guest-grpc-runtime-map.json" || return 1
  remote_sudo "${backend_guest_host}" /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-guest/${backend_port_id}/dns/cache_runtime_control" \
    >"${out_dir}/systemd/backend-guest-dns-runtime-map.json" || return 1
  remote_sudo "${backend_guest_host}" /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-guest/${backend_port_id}/grpc/cache_runtime_control" \
    >"${out_dir}/systemd/backend-guest-grpc-runtime-map.json" || return 1

  "${python_bin}" - \
    "${out_dir}/openstack/fingerprints.json" \
    "${out_dir}/systemd/master-agent-state.json" \
    "${out_dir}/systemd/compute2-agent-state.json" \
    "${out_dir}/systemd/client-guest-state.json" \
    "${out_dir}/systemd/backend-guest-state.json" \
    "${out_dir}/systemd/client-guest-ens3.json" \
    "${out_dir}/systemd/backend-guest-ens3.json" \
    "${out_dir}/systemd/master-client-dns-runtime-map.json" \
    "${out_dir}/systemd/master-client-grpc-runtime-map.json" \
    "${out_dir}/systemd/master-backend-grpc-runtime-map.json" \
    "${out_dir}/systemd/client-guest-grpc-runtime-map.json" \
    "${out_dir}/systemd/backend-guest-dns-runtime-map.json" \
    "${out_dir}/systemd/backend-guest-grpc-runtime-map.json" \
    "${expected_compute_host}" "${compute2_host}" \
    "${client_guest_host}" "${backend_guest_host}" \
    "${client_server_id}" "${client_port_id}" \
    "${backend_server_id}" "${backend_port_id}" \
    "${client_tap}" "${backend_tap}" \
    "${out_dir}/systemd/map-identities.json" <<'PY' || return 1
import json
import sys
from pathlib import Path


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


fingerprints = load(sys.argv[1])
master = load(sys.argv[2])
compute2 = load(sys.argv[3])
client_state = load(sys.argv[4])
backend_state = load(sys.argv[5])
client_link = load(sys.argv[6])
backend_link = load(sys.argv[7])
map_documents = [load(path) for path in sys.argv[8:14]]
(
    expected_host,
    compute2_host,
    client_guest_host,
    backend_guest_host,
    client_server_id,
    client_port_id,
    backend_server_id,
    backend_port_id,
    client_tap,
    backend_tap,
) = sys.argv[14:24]
map_output = Path(sys.argv[24])


def contains(document, value):
    return value in json.dumps(document, sort_keys=True)


expected_servers = {client_server_id, backend_server_id}
if set(master.get("server_ids", [])) != expected_servers:
    raise SystemExit("master state server identities do not match the run")
if master.get("local_host") != expected_host:
    raise SystemExit("master state local_host does not match Neutron binding")
attachments = master.get("attachments")
if not isinstance(attachments, dict) or set(attachments) != {
    client_port_id,
    backend_port_id,
}:
    raise SystemExit("master state does not contain two independent attachments")
for port_id, server_id, interface in (
    (client_port_id, client_server_id, client_tap),
    (backend_port_id, backend_server_id, backend_tap),
):
    record = attachments[port_id]
    binding = record.get("binding") if isinstance(record, dict) else None
    if not isinstance(binding, dict) or {
        "server_id": binding.get("server_id"),
        "port_id": binding.get("port_id"),
        "host": binding.get("host"),
        "interface": binding.get("interface"),
    } != {
        "server_id": server_id,
        "port_id": port_id,
        "host": expected_host,
        "interface": interface,
    }:
        raise SystemExit(f"master attachment binding is stale: {port_id}")
    if not isinstance(binding.get("ifindex"), int) or binding["ifindex"] <= 0:
        raise SystemExit(f"master attachment ifindex is invalid: {port_id}")
    if record.get("healthy") is not True or record.get("missing_pins") != []:
        raise SystemExit(f"master attachment is not healthy: {port_id}")
    if record.get("hook_ownership_verified") is not True:
        raise SystemExit(f"master hook ownership is not verified: {port_id}")
    expected_programs = record.get("program_ids")
    current_programs = record.get("current_program_ids")
    if not isinstance(expected_programs, dict) or current_programs != expected_programs:
        raise SystemExit(f"master hook program IDs changed: {port_id}")
    for name, program_id in expected_programs.items():
        if name == "dns_xdp" and program_id is None:
            continue
        if not isinstance(program_id, int) or program_id <= 0:
            raise SystemExit(f"master hook program ID is invalid: {port_id}/{name}")

if set(compute2.get("server_ids", [])) != expected_servers:
    raise SystemExit("compute2 state server identities do not match the run")
if compute2.get("local_host") != compute2_host:
    raise SystemExit("compute2 state has an unexpected local_host")
compute2_attachments = compute2.get("attachments")
if not isinstance(compute2_attachments, dict) or any(
    port_id in compute2_attachments for port_id in (client_port_id, backend_port_id)
):
    raise SystemExit("compute2 unexpectedly owns a master-bound attachment")

for role, state, link in (
    ("client", client_state, client_link),
    ("backend", backend_state, backend_link),
):
    expected = fingerprints[role]
    if not contains(state, expected["server_id"]) or not contains(
        state, expected["port_id"]
    ):
        raise SystemExit(f"{role} guest state does not match OpenStack identity")
    if not isinstance(link, list) or len(link) != 1:
        raise SystemExit(f"{role} guest ens3 evidence is not a single link")
    actual_mac = str(link[0].get("address", "")).lower()
    addresses = {
        item.get("local")
        for item in link[0].get("addr_info", [])
        if isinstance(item, dict) and item.get("family") == "inet"
    }
    if actual_mac != expected["mac"] or expected["ip"] not in addresses:
        raise SystemExit(f"{role} guest ens3 MAC/IP differs from Neutron port")


def map_identity(label, node, path, value):
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    if not isinstance(value, dict):
        raise SystemExit("bpftool pinned map output is invalid")
    map_id = value.get("id")
    if not isinstance(map_id, int) or map_id <= 0:
        raise SystemExit("bpftool pinned map has an invalid ID")
    map_type = value.get("type")
    key_size = value.get("bytes_key")
    value_size = value.get("bytes_value")
    max_entries = value.get("max_entries")
    if not isinstance(map_type, str) or not map_type:
        raise SystemExit(f"bpftool pinned map has an invalid type: {label}")
    for field, item in (
        ("key_size", key_size),
        ("value_size", value_size),
        ("max_entries", max_entries),
    ):
        if not isinstance(item, int) or item <= 0:
            raise SystemExit(f"bpftool pinned map has invalid {field}: {label}")
    return {
        "node": node,
        "path": path,
        "id": map_id,
        "type": map_type,
        "key_size": key_size,
        "value_size": value_size,
        "max_entries": max_entries,
    }


map_specs = (
    (
        "master_client_dns",
        expected_host,
        f"/sys/fs/bpf/vnet-dataplane-agent/{client_port_id}/dns/cache_runtime_control",
    ),
    (
        "master_client_grpc",
        expected_host,
        f"/sys/fs/bpf/vnet-dataplane-agent/{client_port_id}/grpc/cache_runtime_control",
    ),
    (
        "master_backend_grpc",
        expected_host,
        f"/sys/fs/bpf/vnet-dataplane-agent/{backend_port_id}/grpc/cache_runtime_control",
    ),
    (
        "client_guest_grpc",
        client_guest_host,
        f"/sys/fs/bpf/vnet-dataplane-guest/{client_port_id}/grpc/cache_runtime_control",
    ),
    (
        "backend_guest_dns",
        backend_guest_host,
        f"/sys/fs/bpf/vnet-dataplane-guest/{backend_port_id}/dns/cache_runtime_control",
    ),
    (
        "backend_guest_grpc",
        backend_guest_host,
        f"/sys/fs/bpf/vnet-dataplane-guest/{backend_port_id}/grpc/cache_runtime_control",
    ),
)
identities = {
    label: map_identity(label, node, path, document)
    for (label, node, path), document in zip(map_specs, map_documents)
}
master_ids = {
    identities[label]["id"]
    for label in ("master_client_dns", "master_client_grpc", "master_backend_grpc")
}
if len(master_ids) != 3:
    raise SystemExit("master runtime maps are not independent")
if identities["master_client_grpc"]["id"] == identities["master_backend_grpc"]["id"]:
    raise SystemExit("master client/backend gRPC runtime maps are not independent")
if identities["backend_guest_dns"]["id"] == identities["backend_guest_grpc"]["id"]:
    raise SystemExit("backend guest DNS/gRPC runtime maps are not independent")
map_output.write_text(
    json.dumps(
        {
            "schema_version": 1,
            "maps": identities,
            "checks": {
                "master_maps_independent": True,
                "master_client_backend_grpc_independent": True,
                "backend_guest_protocol_maps_independent": True,
            },
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    + "\n",
    encoding="utf-8",
)
PY
  recheck_openstack_fingerprints attach || return 1
}

audit_running_stack() {
  local deadline=$((SECONDS + attach_timeout))
  while (( SECONDS <= deadline )); do
    if local_sudo /usr/bin/systemctl is-active --quiet "${host_agent_unit}" &&
       remote_sudo_probe "${compute2_host}" /usr/bin/systemctl is-active --quiet "${host_agent_unit}" &&
       remote_sudo_probe "${client_guest_host}" /usr/bin/systemctl is-active --quiet "${guest_agent_unit}" &&
       remote_sudo_probe "${backend_guest_host}" /usr/bin/systemctl is-active --quiet "${guest_agent_unit}" &&
       local_sudo /usr/bin/grep -q "${client_port_id}" /run/vnet-dataplane-agent/state.json &&
       local_sudo /usr/bin/grep -q "${backend_port_id}" /run/vnet-dataplane-agent/state.json &&
       local_sudo /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}/dns/cache_runtime_control" &&
       local_sudo /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}/grpc/cache_runtime_control" &&
       local_sudo /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}/grpc/cache_runtime_control" &&
       local_sudo /usr/bin/python3 /opt/vnet-dataplane/linux_accel/agent/openstack_dataplane_agent.py health \
         --state-file /run/vnet-dataplane-agent/state.json \
         --server-id "${client_server_id}" --server-id "${backend_server_id}" \
         --max-age-seconds 20 >/dev/null &&
       remote_sudo_probe "${client_guest_host}" /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-guest/${client_port_id}/grpc/cache_runtime_control" &&
       remote_sudo_probe "${backend_guest_host}" /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-guest/${backend_port_id}/dns/cache_runtime_control" &&
       remote_sudo_probe "${backend_guest_host}" /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-guest/${backend_port_id}/grpc/cache_runtime_control" &&
       remote_sudo_probe "${client_guest_host}" /usr/bin/python3 \
         /opt/vnet-dataplane/linux_accel/agent/openstack_guest_endpoint_agent.py health \
         --config /etc/vnet-dataplane-guest/endpoint.json \
         --state-file /run/vnet-dataplane-guest/state.json \
         --max-age-seconds 20 >/dev/null &&
       remote_sudo_probe "${backend_guest_host}" /usr/bin/python3 \
         /opt/vnet-dataplane/linux_accel/agent/openstack_guest_endpoint_agent.py health \
         --config /etc/vnet-dataplane-guest/endpoint.json \
         --state-file /run/vnet-dataplane-guest/state.json \
         --max-age-seconds 20 >/dev/null &&
       capture_running_stack_evidence; then
      return 0
    fi
    sleep 0.2
  done
  echo "systemd agents did not expose matching independent endpoint pins within ${attach_timeout}s" >&2
  return 1
}

read_current_epoch() {
  if ! local_sudo /usr/bin/test -r "${coordinator_state_file}"; then
    printf '%s\n' 0
    return
  fi
  local_sudo /usr/bin/python3 -c \
    'import json,sys; value=json.load(open(sys.argv[1],encoding="utf-8")); epoch=value.get("epoch",0); print(epoch if isinstance(epoch,int) and not isinstance(epoch,bool) and epoch>=0 else 0)' \
    "${coordinator_state_file}"
}

wait_committed() {
  local target_mode="$1"
  local after_epoch="$2"
  local proof="${3:-publication}"
  local command=(
    /usr/bin/python3 "${coordinator_script}" wait-committed
    --config "${coordinator_config}"
    --desired-mode-file "${desired_mode_file}"
    --state-file "${coordinator_state_file}"
    --audit-log "${coordinator_audit_log}"
    --target-mode "${target_mode}"
    --after-epoch "${after_epoch}"
    --min-present-readbacks 4
    --timeout "${commit_timeout}"
    --interval 0.1
  )
  if [[ "${proof}" == shutdown ]]; then
    command+=(--require-shutdown)
  elif [[ "${proof}" != publication ]]; then
    echo "unknown committed proof type: ${proof}" >&2
    return 2
  fi
  local_sudo "${command[@]}"
}

run_workload() {
  local protocol="$1"
  case "${protocol}" in
    dns)
      remote_exec "${client_guest_host}" \
        /opt/vnet-dataplane/linux_accel/build/openstack_dns_harness \
        client-workload "${backend_ip}" 53 dynamic.test "${backend_ip}" \
        "${requests}" "${warmup}" hot 1
      ;;
    grpc)
      remote_exec "${client_guest_host}" \
        /opt/vnet-dataplane/linux_accel/build/openstack_grpc_harness \
        client "${backend_ip}" 50052 "${requests}" "${warmup}" health-check
      ;;
    *)
      echo "unknown workload protocol: ${protocol}" >&2
      return 2
      ;;
  esac
}

snapshot_metrics() {
  local phase="$1"
  local dns_count_file="${out_dir}/raw/${phase}.dns-backend-count.txt"
  local dns_stats_file="${out_dir}/raw/${phase}.dns-cache-stats.txt"
  local grpc_stats_file="${out_dir}/raw/${phase}.grpc-cache-stats.txt"

  remote_sudo "${backend_guest_host}" /usr/bin/cat \
    /var/log/vnet-dataplane-guest/dns-count >"${dns_count_file}"
  remote_sudo "${backend_guest_host}" \
    /opt/vnet-dataplane/linux_accel/build/dns_cache_stats_reader \
    "/sys/fs/bpf/vnet-dataplane-guest/${backend_port_id}/dns/dns_cache_stats" \
    >"${dns_stats_file}"
  remote_sudo "${backend_guest_host}" /usr/bin/tail -n 64 \
    "/var/log/vnet-dataplane-guest/${backend_port_id}/grpc-fast-cache.log" |
    grep 'grpc_fast_cache listen=' |
    tail -n 1 >"${grpc_stats_file}"

  "${python_bin}" - "${dns_count_file}" "${dns_stats_file}" \
    "${grpc_stats_file}" <<'PY'
import json
import re
import sys
from pathlib import Path


def fields(path):
    text = Path(path).read_text(encoding="utf-8")
    return {
        key: int(value)
        for key, value in re.findall(r"([a-z_]+)=([0-9]+)", text)
    }


dns_count_text = Path(sys.argv[1]).read_text(encoding="utf-8").strip().splitlines()
if not dns_count_text or not dns_count_text[-1].isdigit():
    raise SystemExit("invalid DNS backend count")
dns = fields(sys.argv[2])
grpc = fields(sys.argv[3])
required_dns = ("cache_hit", "cache_tx", "cache_miss", "policy_bypass")
required_grpc = (
    "accepted",
    "cache_hit",
    "serving_cache_hit",
    "fallback",
    "fallback_error",
    "parse_error",
    "policy_bypass",
    "tx_error",
    "runtime_epoch",
)
for key in required_dns:
    if key not in dns:
        raise SystemExit(f"missing DNS metric: {key}")
for key in required_grpc:
    if key not in grpc:
        raise SystemExit(f"missing gRPC metric: {key}")
result = {"dns_backend_count": int(dns_count_text[-1])}
result.update({f"dns_{key}": dns[key] for key in required_dns})
result.update({f"grpc_{key}": grpc[key] for key in required_grpc})
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
}

assert_unit_inactive_local() {
  local unit="$1"
  local state
  state="$(local_sudo /usr/bin/systemctl show \
    -p LoadState -p ActiveState -p SubState -p Result "${unit}")" || return 1
  grep -q '^LoadState=loaded$' <<<"${state}" &&
    grep -q '^ActiveState=inactive$' <<<"${state}" &&
    grep -q '^SubState=dead$' <<<"${state}" &&
    grep -q '^Result=success$' <<<"${state}"
}

assert_unit_inactive_remote() {
  local host="$1"
  local unit="$2"
  local state
  state="$(remote_sudo_probe "${host}" /usr/bin/systemctl show \
    -p LoadState -p ActiveState -p SubState -p Result "${unit}")" || return 1
  grep -q '^LoadState=loaded$' <<<"${state}" &&
    grep -q '^ActiveState=inactive$' <<<"${state}" &&
    grep -q '^SubState=dead$' <<<"${state}" &&
    grep -q '^Result=success$' <<<"${state}"
}

assert_no_process_local() {
  local pattern="$1"
  local process_status
  local_sudo /usr/bin/pgrep -af "${pattern}" >/dev/null 2>&1
  process_status=$?
  [[ "${process_status}" == 1 ]]
}

assert_no_process_remote() {
  local host="$1"
  local pattern="$2"
  local process_status
  remote_sudo_probe "${host}" /usr/bin/pgrep -af "${pattern}" >/dev/null 2>&1
  process_status=$?
  [[ "${process_status}" == 1 ]]
}

audit_tc_cleanup() {
  local tap="$1"
  local ingress="${out_dir}/systemd/${tap}.tc-ingress.txt"
  local egress="${out_dir}/systemd/${tap}.tc-egress.txt"
  local status=0
  local_sudo /usr/sbin/tc filter show dev "${tap}" ingress >"${ingress}" || status=1
  local_sudo /usr/sbin/tc filter show dev "${tap}" egress >"${egress}" || status=1
  if grep -Eq 'handle 0x1 |handle 0x2 ' "${ingress}" "${egress}"; then
    echo "run-owned TC hook remains on ${tap}" >&2
    status=1
  fi
  if [[ "${require_netmig_tc}" == 1 ]]; then
    local ingress_identity="${out_dir}/systemd/${tap}.netmig-ingress-after.json"
    local egress_identity="${out_dir}/systemd/${tap}.netmig-egress-after.json"
    capture_tc_identity "${tap}" ingress 0x65 "${ingress_identity}" || status=1
    capture_tc_identity "${tap}" egress 0x66 "${egress_identity}" || status=1
    if ! cmp -s \
      "${out_dir}/systemd/${tap}.netmig-ingress-before.json" \
      "${ingress_identity}"; then
      echo "NetMig ingress program identity changed on ${tap}" >&2
      status=1
    fi
    if ! cmp -s \
      "${out_dir}/systemd/${tap}.netmig-egress-before.json" \
      "${egress_identity}"; then
      echo "NetMig egress program identity changed on ${tap}" >&2
      status=1
    fi
  fi
  return "${status}"
}

capture_unit_inactive_local() {
  local unit="$1"
  local raw="$2"
  local_sudo /usr/bin/systemctl show \
    -p LoadState -p ActiveState -p SubState -p Result "${unit}" \
    >"${raw}" 2>&1 || return 1
  grep -q '^LoadState=loaded$' "${raw}" &&
    grep -q '^ActiveState=inactive$' "${raw}" &&
    grep -q '^SubState=dead$' "${raw}" &&
    grep -q '^Result=success$' "${raw}"
}

capture_unit_inactive_remote() {
  local host="$1"
  local unit="$2"
  local raw="$3"
  remote_sudo_probe "${host}" /usr/bin/systemctl show \
    -p LoadState -p ActiveState -p SubState -p Result "${unit}" \
    >"${raw}" 2>&1 || return 1
  grep -q '^LoadState=loaded$' "${raw}" &&
    grep -q '^ActiveState=inactive$' "${raw}" &&
    grep -q '^SubState=dead$' "${raw}" &&
    grep -q '^Result=success$' "${raw}"
}

capture_path_absent_local() {
  local path="$1"
  local raw="$2"
  local rc=0
  if local_sudo /usr/bin/test ! -e "${path}"; then
    printf 'absent\t%s\n' "${path}" >"${raw}"
    return 0
  else
    rc=$?
  fi
  printf 'not-absent-or-probe-error=%s\t%s\n' "${rc}" "${path}" >"${raw}"
  return "${rc}"
}

capture_path_absent_remote() {
  local host="$1"
  local path="$2"
  local raw="$3"
  local rc=0
  if remote_sudo_probe "${host}" /usr/bin/test ! -e "${path}"; then
    printf 'absent\t%s\t%s\n' "${host}" "${path}" >"${raw}"
    return 0
  else
    rc=$?
  fi
  printf 'not-absent-or-probe-error=%s\t%s\t%s\n' \
    "${rc}" "${host}" "${path}" >"${raw}"
  return "${rc}"
}

capture_process_absent_local() {
  local pattern="$1"
  local raw="$2"
  local rc=0
  local_sudo /usr/bin/pgrep -af "${pattern}" >"${raw}" 2>&1 || rc=$?
  if (( rc == 1 )); then
    printf '%s\n' 'no matching process' >>"${raw}"
    return 0
  fi
  (( rc == 0 )) && return 1
  return "${rc}"
}

capture_process_absent_remote() {
  local host="$1"
  local pattern="$2"
  local raw="$3"
  local rc=0
  remote_sudo_probe "${host}" /usr/bin/pgrep -af "${pattern}" \
    >"${raw}" 2>&1 || rc=$?
  if (( rc == 1 )); then
    printf '%s\n' 'no matching process' >>"${raw}"
    return 0
  fi
  (( rc == 0 )) && return 1
  return "${rc}"
}

write_cleanup_evidence() {
  local checks_file="$1"
  local evidence_file="${out_dir}/cleanup-evidence.json"
  "${python_bin}" - "${out_dir}" "${checks_file}" "${evidence_file}" \
    "${cleanup_audit_only}" "${execution_mode}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
checks_path = pathlib.Path(sys.argv[2])
evidence_path = pathlib.Path(sys.argv[3])
cleanup_audit_only = sys.argv[4] == "1"
execution_mode = sys.argv[5]
checks = {}
for line in checks_path.read_text(encoding="utf-8").splitlines():
    name, value = line.split("\t", 1)
    if value not in {"true", "false"}:
        raise SystemExit(f"invalid cleanup check value: {name}={value}")
    checks[name] = value == "true"

required = {
    "units_inactive",
    "pins_removed",
    "quiesce_removed",
    "processes_absent",
    "xdp_detached",
    "listeners_absent",
    "tc_cleanup",
}
if set(checks) != required:
    raise SystemExit("cleanup check set is incomplete")

raw_files = []
for path in sorted((root / "cleanup" / "raw").glob("*")):
    if path.is_file():
        raw_files.append(path.relative_to(root).as_posix())
for path in sorted((root / "systemd").glob("*.tc-*.txt")):
    if path.is_file():
        raw_files.append(path.relative_to(root).as_posix())
for path in sorted((root / "systemd").glob("*.netmig-*-after.json")):
    if path.is_file():
        raw_files.append(path.relative_to(root).as_posix())

evidence = {
    "schema": 1,
    "passed": all(checks.values()),
    "checks": checks,
    "netmig_baseline_scope": (
        "test_driver"
        if execution_mode == "test_driver"
        else "audit_start" if cleanup_audit_only else "run_preflight"
    ),
    "raw_files": raw_files,
}
evidence_path.write_text(
    json.dumps(evidence, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

validate_cleanup_evidence() {
  local evidence_file="${out_dir}/cleanup-evidence.json"
  [[ -s "${evidence_file}" ]] || {
    echo "cleanup audit did not produce cleanup-evidence.json" >&2
    return 1
  }
  "${python_bin}" - "${out_dir}" "${evidence_file}" \
    "${cleanup_audit_only}" "${execution_mode}" "${require_netmig_tc}" \
    "${client_tap}" "${backend_tap}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
evidence_path = pathlib.Path(sys.argv[2])
cleanup_audit_only = sys.argv[3] == "1"
execution_mode = sys.argv[4]
require_netmig_tc = sys.argv[5] == "1"
client_tap = sys.argv[6]
backend_tap = sys.argv[7]
evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
expected_baseline_scope = (
    "test_driver"
    if execution_mode == "test_driver"
    else "audit_start" if cleanup_audit_only else "run_preflight"
)
required = {
    "units_inactive",
    "pins_removed",
    "quiesce_removed",
    "processes_absent",
    "xdp_detached",
    "listeners_absent",
    "tc_cleanup",
}
checks = evidence.get("checks")
if evidence.get("schema") != 1 or evidence.get("passed") is not True:
    raise SystemExit("cleanup evidence is not a passing schema-1 document")
if evidence.get("netmig_baseline_scope") != expected_baseline_scope:
    raise SystemExit("cleanup evidence has an incorrect NetMig baseline scope")
if not isinstance(checks, dict) or set(checks) != required:
    raise SystemExit("cleanup evidence has an incomplete check set")
if any(value is not True for value in checks.values()):
    raise SystemExit("cleanup evidence contains a failed check")
raw_files = evidence.get("raw_files")
if not isinstance(raw_files, list) or not raw_files:
    raise SystemExit("cleanup evidence has no raw observations")
if len(raw_files) != len(set(raw_files)):
    raise SystemExit("cleanup evidence contains duplicate raw file entries")
for value in raw_files:
    if not isinstance(value, str):
        raise SystemExit("cleanup raw file entry is not a string")
    relative = pathlib.PurePosixPath(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(f"unsafe cleanup raw file path: {value}")
    path = root.joinpath(*relative.parts).resolve()
    if root not in path.parents or not path.is_file():
        raise SystemExit(f"missing cleanup raw file: {value}")

if execution_mode == "real":
    raw_names = {
        "master-coordinator.systemctl.txt",
        "master-metrics.systemctl.txt",
        "master-agent.systemctl.txt",
        "compute2-agent.systemctl.txt",
        "client-guest-agent.systemctl.txt",
        "backend-guest-agent.systemctl.txt",
        "backend-dns.systemctl.txt",
        "backend-grpc.systemctl.txt",
        "master-client-pin.txt",
        "master-backend-pin.txt",
        "compute2-client-pin.txt",
        "compute2-backend-pin.txt",
        "client-guest-pin.txt",
        "backend-guest-pin.txt",
        "master-client-quiesce.txt",
        "master-backend-quiesce.txt",
        "compute2-client-quiesce.txt",
        "compute2-backend-quiesce.txt",
        "client-guest-quiesce.txt",
        "backend-guest-quiesce.txt",
        "master-agent.pgrep.txt",
        "master-coordinator.pgrep.txt",
        "master-metrics.pgrep.txt",
        "compute2-agent.pgrep.txt",
        "client-guest-agent.pgrep.txt",
        "backend-guest-agent.pgrep.txt",
        "client-grpc-cache.pgrep.txt",
        "backend-grpc-cache.pgrep.txt",
        "backend-dns-monitor.pgrep.txt",
        "client-dns-harness.pgrep.txt",
        "backend-dns-harness.pgrep.txt",
        "client-grpc-harness.pgrep.txt",
        "backend-grpc-harness.pgrep.txt",
        "master-client-tap.ip-link.txt",
        "master-backend-tap.ip-link.txt",
        "backend-guest-ens3.ip-link.txt",
        "backend-guest.ss-udp.txt",
        "backend-guest.ss-tcp.txt",
        "client-guest.ss-tcp.txt",
    }
    expected = {f"cleanup/raw/{name}" for name in raw_names}
    for tap in (client_tap, backend_tap):
        expected.update(
            {
                f"systemd/{tap}.tc-ingress.txt",
                f"systemd/{tap}.tc-egress.txt",
            }
        )
        if require_netmig_tc:
            expected.update(
                {
                    f"systemd/{tap}.netmig-ingress-after.json",
                    f"systemd/{tap}.netmig-egress-after.json",
                }
            )
    missing = sorted(expected - set(raw_files))
    if missing:
        raise SystemExit("cleanup evidence is missing raw files: " + ",".join(missing))
PY
}

audit_cleanup() {
  local status=0
  local raw_dir="${out_dir}/cleanup/raw"
  local checks_file="${out_dir}/cleanup/checks.tsv"
  local units_inactive=true pins_removed=true quiesce_removed=true
  local processes_absent=true xdp_detached=true listeners_absent=true
  local tc_cleanup=true
  mkdir -p "${raw_dir}"

  capture_unit_inactive_local "${coordinator_unit}" "${raw_dir}/master-coordinator.systemctl.txt" || units_inactive=false
  capture_unit_inactive_local "${metrics_unit}" "${raw_dir}/master-metrics.systemctl.txt" || units_inactive=false
  capture_unit_inactive_local "${host_agent_unit}" "${raw_dir}/master-agent.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${compute2_host}" "${host_agent_unit}" "${raw_dir}/compute2-agent.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${client_guest_host}" "${guest_agent_unit}" "${raw_dir}/client-guest-agent.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${backend_guest_host}" "${guest_agent_unit}" "${raw_dir}/backend-guest-agent.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${backend_guest_host}" "${dns_backend_unit}" "${raw_dir}/backend-dns.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${backend_guest_host}" "${grpc_backend_unit}" "${raw_dir}/backend-grpc.systemctl.txt" || units_inactive=false
  [[ "${units_inactive}" == true ]] || status=1

  capture_path_absent_local "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}" "${raw_dir}/master-client-pin.txt" || pins_removed=false
  capture_path_absent_local "/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}" "${raw_dir}/master-backend-pin.txt" || pins_removed=false
  capture_path_absent_remote "${compute2_host}" "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}" "${raw_dir}/compute2-client-pin.txt" || pins_removed=false
  capture_path_absent_remote "${compute2_host}" "/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}" "${raw_dir}/compute2-backend-pin.txt" || pins_removed=false
  capture_path_absent_remote "${client_guest_host}" "/sys/fs/bpf/vnet-dataplane-guest/${client_port_id}" "${raw_dir}/client-guest-pin.txt" || pins_removed=false
  capture_path_absent_remote "${backend_guest_host}" "/sys/fs/bpf/vnet-dataplane-guest/${backend_port_id}" "${raw_dir}/backend-guest-pin.txt" || pins_removed=false
  [[ "${pins_removed}" == true ]] || status=1

  capture_path_absent_local "/run/vnet-dataplane-policy/vnet-dataplane-${client_port_id}.quiesce" "${raw_dir}/master-client-quiesce.txt" || quiesce_removed=false
  capture_path_absent_local "/run/vnet-dataplane-policy/vnet-dataplane-${backend_port_id}.quiesce" "${raw_dir}/master-backend-quiesce.txt" || quiesce_removed=false
  capture_path_absent_remote "${compute2_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${client_port_id}.quiesce" "${raw_dir}/compute2-client-quiesce.txt" || quiesce_removed=false
  capture_path_absent_remote "${compute2_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${backend_port_id}.quiesce" "${raw_dir}/compute2-backend-quiesce.txt" || quiesce_removed=false
  capture_path_absent_remote "${client_guest_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${client_port_id}.quiesce" "${raw_dir}/client-guest-quiesce.txt" || quiesce_removed=false
  capture_path_absent_remote "${backend_guest_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${backend_port_id}.quiesce" "${raw_dir}/backend-guest-quiesce.txt" || quiesce_removed=false
  [[ "${quiesce_removed}" == true ]] || status=1

  capture_process_absent_local '[o]penstack_dataplane_agent.py' "${raw_dir}/master-agent.pgrep.txt" || processes_absent=false
  capture_process_absent_local '[o]penstack_epoch_coordinator.py' "${raw_dir}/master-coordinator.pgrep.txt" || processes_absent=false
  capture_process_absent_local '[o]penstack_metrics_bridge.py' "${raw_dir}/master-metrics.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${compute2_host}" '[o]penstack_dataplane_agent.py' "${raw_dir}/compute2-agent.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${client_guest_host}" '[o]penstack_guest_endpoint_agent.py' "${raw_dir}/client-guest-agent.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${backend_guest_host}" '[o]penstack_guest_endpoint_agent.py' "${raw_dir}/backend-guest-agent.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${client_guest_host}" '[g]rpc_fast_cache' "${raw_dir}/client-grpc-cache.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${backend_guest_host}" '[g]rpc_fast_cache' "${raw_dir}/backend-grpc-cache.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${backend_guest_host}" '[d]ns_monitor' "${raw_dir}/backend-dns-monitor.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${client_guest_host}" '[o]penstack_dns_harness' "${raw_dir}/client-dns-harness.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${backend_guest_host}" '[o]penstack_dns_harness' "${raw_dir}/backend-dns-harness.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${client_guest_host}" '[o]penstack_grpc_harness' "${raw_dir}/client-grpc-harness.pgrep.txt" || processes_absent=false
  capture_process_absent_remote "${backend_guest_host}" '[o]penstack_grpc_harness' "${raw_dir}/backend-grpc-harness.pgrep.txt" || processes_absent=false
  [[ "${processes_absent}" == true ]] || status=1

  if ! local_sudo /usr/sbin/ip -details link show dev "${client_tap}" >"${raw_dir}/master-client-tap.ip-link.txt" 2>&1; then
    xdp_detached=false
  elif grep -q 'prog/xdp' "${raw_dir}/master-client-tap.ip-link.txt"; then
    echo "client host XDP hook remains after cleanup" >&2
    xdp_detached=false
  fi
  if ! local_sudo /usr/sbin/ip -details link show dev "${backend_tap}" >"${raw_dir}/master-backend-tap.ip-link.txt" 2>&1; then
    xdp_detached=false
  elif grep -q 'prog/xdp' "${raw_dir}/master-backend-tap.ip-link.txt"; then
    echo "backend host XDP hook remains after cleanup" >&2
    xdp_detached=false
  fi
  if ! remote_sudo "${backend_guest_host}" /usr/sbin/ip -details link show dev ens3 >"${raw_dir}/backend-guest-ens3.ip-link.txt" 2>&1; then
    xdp_detached=false
  elif grep -q 'prog/xdp' "${raw_dir}/backend-guest-ens3.ip-link.txt"; then
    echo "backend guest XDP hook remains after cleanup" >&2
    xdp_detached=false
  fi
  [[ "${xdp_detached}" == true ]] || status=1

  if ! remote_sudo "${backend_guest_host}" /usr/bin/ss -H -lunp >"${raw_dir}/backend-guest.ss-udp.txt" 2>&1; then
    listeners_absent=false
  elif grep -Fq "${backend_ip}:53 " "${raw_dir}/backend-guest.ss-udp.txt" ||
       grep -Fq '0.0.0.0:53 ' "${raw_dir}/backend-guest.ss-udp.txt"; then
    echo "backend DNS listener remains after cleanup" >&2
    listeners_absent=false
  fi
  if ! remote_sudo "${backend_guest_host}" /usr/bin/ss -H -ltnp >"${raw_dir}/backend-guest.ss-tcp.txt" 2>&1; then
    listeners_absent=false
  elif grep -Eq ':(50051|50052) ' "${raw_dir}/backend-guest.ss-tcp.txt"; then
    echo "backend gRPC listener remains after cleanup" >&2
    listeners_absent=false
  fi
  if ! remote_sudo "${client_guest_host}" /usr/bin/ss -H -ltnp >"${raw_dir}/client-guest.ss-tcp.txt" 2>&1; then
    listeners_absent=false
  elif grep -Eq ':(50052|50053) ' "${raw_dir}/client-guest.ss-tcp.txt"; then
    echo "client gRPC listener remains after cleanup" >&2
    listeners_absent=false
  fi
  [[ "${listeners_absent}" == true ]] || status=1

  audit_tc_cleanup "${client_tap}" || tc_cleanup=false
  audit_tc_cleanup "${backend_tap}" || tc_cleanup=false
  [[ "${tc_cleanup}" == true ]] || status=1

  {
    printf 'units_inactive\t%s\n' "${units_inactive}"
    printf 'pins_removed\t%s\n' "${pins_removed}"
    printf 'quiesce_removed\t%s\n' "${quiesce_removed}"
    printf 'processes_absent\t%s\n' "${processes_absent}"
    printf 'xdp_detached\t%s\n' "${xdp_detached}"
    printf 'listeners_absent\t%s\n' "${listeners_absent}"
    printf 'tc_cleanup\t%s\n' "${tc_cleanup}"
  } >"${checks_file}"
  write_cleanup_evidence "${checks_file}" || status=1
  return "${status}"
}

production_action() {
  local action="$1"
  shift
  case "${action}" in
    preflight)
      preflight
      ;;
    deploy)
      deploy_or_verify
      ;;
    service)
      local scope="$1" node="$2" operation="$3" unit="$4"
      if [[ "${scope}" == local ]]; then
        systemctl_local "${operation}" "${unit}"
      else
        systemctl_remote "${node}" "${operation}" "${unit}"
      fi
      ;;
    audit-running)
      audit_running_stack
      ;;
    read-epoch)
      read_current_epoch
      ;;
    wait-committed)
      wait_committed "$1" "$2" "${3:-publication}"
      ;;
    workload)
      run_workload "$1"
      ;;
    snapshot)
      snapshot_metrics "$1"
      ;;
    audit-cleanup)
      audit_cleanup
      ;;
    *)
      echo "unknown E2E action: ${action}" >&2
      return 2
      ;;
  esac
}

action() {
  if [[ -n "${action_driver}" ]]; then
    "${action_driver}" "$@"
  else
    production_action "$@"
  fi
}

stop_services() {
  local status=0
  action service local master stop "${coordinator_unit}" || status=1
  action service local master stop "${metrics_unit}" || status=1
  action service remote "${compute2_host}" stop "${host_agent_unit}" || status=1
  action service local master stop "${host_agent_unit}" || status=1
  action service remote "${client_guest_host}" stop "${guest_agent_unit}" || status=1
  action service remote "${backend_guest_host}" stop "${guest_agent_unit}" || status=1
  action service remote "${backend_guest_host}" stop "${grpc_backend_unit}" || status=1
  action service remote "${backend_guest_host}" stop "${dns_backend_unit}" || status=1
  return "${status}"
}

start_services() {
  action service remote "${backend_guest_host}" start "${dns_backend_unit}"
  action service remote "${backend_guest_host}" start "${grpc_backend_unit}"
  action service remote "${backend_guest_host}" start "${guest_agent_unit}"
  action service remote "${client_guest_host}" start "${guest_agent_unit}"
  action service remote "${compute2_host}" start "${host_agent_unit}"
  action service local master start "${host_agent_unit}"
  action audit-running
  action service local master start "${metrics_unit}"
  coordinator_started=1
  action service local master start "${coordinator_unit}"
}

json_epoch() {
  "${python_bin}" -c \
    'import json,sys; value=json.load(open(sys.argv[1],encoding="utf-8")); epoch=value.get("epoch"); assert isinstance(epoch,int) and not isinstance(epoch,bool) and epoch>0; print(epoch)' \
    "$1"
}

verify_smoke() {
  "${python_bin}" - \
    "${out_dir}/snapshot-before.json" \
    "${out_dir}/snapshot-after.json" \
    "${out_dir}/measured-dns.txt" \
    "${out_dir}/measured-grpc.txt" \
    "${requests}" "${total_requests}" "${server_epoch}" \
    "${out_dir}/verification.json" <<'PY' || return 1
import json
import re
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"snapshot is not an object: {path}")
    return value


def line_fields(path):
    text = Path(path).read_text(encoding="utf-8")
    pairs = dict(re.findall(r"([a-z_]+)=([^\s]+)", text))
    return pairs


before = load(sys.argv[1])
after = load(sys.argv[2])
dns = line_fields(sys.argv[3])
grpc = line_fields(sys.argv[4])
requests = int(sys.argv[5])
total = int(sys.argv[6])
server_epoch = int(sys.argv[7])
output = Path(sys.argv[8])

checks = {
    "dns_workload_success": int(dns.get("success", -1)) == requests,
    "dns_workload_no_failure": int(dns.get("failed", -1)) == 0,
    "grpc_workload_success": int(grpc.get("serving", -1)) == requests,
    "grpc_workload_no_failure": int(grpc.get("failed", -1)) == 0,
    "dns_backend_suppressed": after["dns_backend_count"] == before["dns_backend_count"],
    "dns_cache_hit_delta": after["dns_cache_hit"] - before["dns_cache_hit"] >= total,
    "dns_cache_tx_delta": after["dns_cache_tx"] - before["dns_cache_tx"] >= total,
    "dns_cache_miss_stable": after["dns_cache_miss"] == before["dns_cache_miss"],
    "dns_policy_bypass_stable": after["dns_policy_bypass"] == before["dns_policy_bypass"],
    "grpc_accepted_delta": after["grpc_accepted"] - before["grpc_accepted"] >= total,
    "grpc_cache_hit_delta": after["grpc_cache_hit"] - before["grpc_cache_hit"] >= total,
    "grpc_serving_hit_delta": after["grpc_serving_cache_hit"] - before["grpc_serving_cache_hit"] >= total,
    "grpc_fallback_stable": after["grpc_fallback"] == before["grpc_fallback"],
    "grpc_fallback_error_stable": after["grpc_fallback_error"] == before["grpc_fallback_error"],
    "grpc_parse_error_stable": after["grpc_parse_error"] == before["grpc_parse_error"],
    "grpc_policy_bypass_stable": after["grpc_policy_bypass"] == before["grpc_policy_bypass"],
    "grpc_tx_error_stable": after["grpc_tx_error"] == before["grpc_tx_error"],
    "grpc_runtime_epoch": after["grpc_runtime_epoch"] == server_epoch,
}
result = {
    "checks": checks,
    "dns_backend_suppressed": checks["dns_backend_suppressed"],
    "passed": all(checks.values()),
}
output.write_text(
    json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
if not result["passed"]:
    failed = sorted(key for key, value in checks.items() if not value)
    raise SystemExit("smoke verification failed: " + ",".join(failed))
PY
  dns_backend_suppressed=true
}

write_summary() {
  local status="$1"
  printf '{"status":"%s","execution_mode":"%s","preflight_only":%s,"cleanup_audit_only":%s,"experiment_executed":%s,"formal_rounds":0,"baseline_epoch":%s,"bypass_epoch":%s,"server_epoch":%s,"dns_backend_suppressed":%s,"dns_acceleration":"guest_xdp_server_cache","grpc_acceleration":"guest_userspace_h2c_fast_cache","grpc_kernel_response":false,"host_tc_role":"observation_and_coexistence","cleanup_status":%s}\n' \
    "${status}" "${execution_mode}" "${preflight_only}" "${cleanup_audit_only}" "${experiment_executed}" \
    "${baseline_epoch}" "${bypass_epoch}" "${server_epoch}" \
    "${dns_backend_suppressed}" "${cleanup_status}" \
    >"${out_dir}/result-summary.json"
}

generate_manifest() {
  (
    cd "${out_dir}"
    find . -type f ! -name sha256sums.txt -print0 |
      sort -z |
      xargs -0 sha256sum >sha256sums.txt
  )
}

close_run_log() {
  local status=0
  (( run_log_closed == 0 )) || return 0
  exec 1>&3 2>&4
  wait "${run_log_pid}" || status=1
  exec 3>&- 4>&-
  run_log_closed=1
  return "${status}"
}

cleanup() {
  local original_status=$?
  local final_status="${run_status}"
  trap - EXIT INT TERM
  if (( cleanup_started != 0 )); then
    exit "${original_status}"
  fi
  cleanup_started=1
  set +e

  if (( mutated != 0 )); then
    action service local master stop "${coordinator_unit}" || cleanup_status=1
    action service local master stop "${metrics_unit}" || cleanup_status=1
    if (( coordinator_started != 0 )); then
      final_after_epoch="${baseline_epoch}"
      (( bypass_epoch > final_after_epoch )) && final_after_epoch="${bypass_epoch}"
      (( server_epoch > final_after_epoch )) && final_after_epoch="${server_epoch}"
      action wait-committed bypass "${final_after_epoch}" shutdown \
        >"${out_dir}/committed-final-bypass.json" \
        2>"${out_dir}/committed-final-bypass.err" || cleanup_status=1
    fi
    action service remote "${compute2_host}" stop "${host_agent_unit}" || cleanup_status=1
    action service local master stop "${host_agent_unit}" || cleanup_status=1
    action service remote "${client_guest_host}" stop "${guest_agent_unit}" || cleanup_status=1
    action service remote "${backend_guest_host}" stop "${guest_agent_unit}" || cleanup_status=1
    action service remote "${backend_guest_host}" stop "${grpc_backend_unit}" || cleanup_status=1
    action service remote "${backend_guest_host}" stop "${dns_backend_unit}" || cleanup_status=1
    if [[ "${execution_mode}" == real ]]; then
      recheck_openstack_fingerprints cleanup || cleanup_status=1
    fi
    action audit-cleanup >"${out_dir}/cleanup-audit.txt" 2>&1 || cleanup_status=1
    validate_cleanup_evidence >>"${out_dir}/cleanup-audit.txt" 2>&1 || cleanup_status=1
  fi

  if (( original_status != 0 || cleanup_status != 0 )); then
    final_status="failed"
  fi
  write_summary "${final_status}"
  close_run_log || cleanup_status=1
  generate_manifest || cleanup_status=1
  if (( cleanup_status != 0 )); then
    write_summary failed
    generate_manifest || true
    exit 1
  fi
  exit "${original_status}"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

action preflight
if [[ "${cleanup_audit_only}" == 1 ]]; then
  if ! action audit-cleanup >"${out_dir}/cleanup-audit.txt" 2>&1; then
    cleanup_status=1
    exit 1
  fi
  if ! validate_cleanup_evidence >>"${out_dir}/cleanup-audit.txt" 2>&1; then
    cleanup_status=1
    exit 1
  fi
  run_status="cleanup_audit_passed"
  exit 0
fi
if [[ "${preflight_only}" == 1 ]]; then
  run_status="preflight_passed"
  exit 0
fi
mutated=1
stop_services
action deploy
baseline_epoch="$(action read-epoch)"
[[ "${baseline_epoch}" =~ ^[0-9]+$ ]] || {
  echo "read-epoch returned an invalid value: ${baseline_epoch}" >&2
  exit 1
}
start_services

action wait-committed bypass "${baseline_epoch}" \
  >"${out_dir}/committed-bypass.json"
bypass_epoch="$(json_epoch "${out_dir}/committed-bypass.json")"

experiment_executed=true
server_ready=0
for window in $(seq 1 "${convergence_windows}"); do
  action workload dns convergence \
    >"${out_dir}/convergence-${window}-dns.txt"
  action workload grpc convergence \
    >"${out_dir}/convergence-${window}-grpc.txt"
  if action wait-committed server "${bypass_epoch}" \
       >"${out_dir}/committed-server-${window}.json" \
       2>"${out_dir}/committed-server-${window}.err"; then
    cp "${out_dir}/committed-server-${window}.json" \
      "${out_dir}/committed-server.json"
    server_ready=1
    break
  fi
done
(( server_ready == 1 )) || {
  echo "dynamic policy did not commit SERVER_CACHE within ${convergence_windows} windows" >&2
  exit 1
}
server_epoch="$(json_epoch "${out_dir}/committed-server.json")"

action snapshot before >"${out_dir}/snapshot-before.json"
action workload dns measured >"${out_dir}/measured-dns.txt"
action workload grpc measured >"${out_dir}/measured-grpc.txt"
measurement_ready=0
for attempt in $(seq 1 100); do
  action snapshot after >"${out_dir}/snapshot-after.json"
  if verify_smoke 2>"${out_dir}/verification.err"; then
    measurement_ready=1
    break
  fi
  sleep 0.1
done
(( measurement_ready == 1 )) || {
  echo "measured counters did not converge within 10 seconds" >&2
  exit 1
}

run_status="passed"
exit 0
