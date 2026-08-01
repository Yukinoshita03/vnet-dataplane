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
source_compute_remote="${SOURCE_COMPUTE_REMOTE:-0}"
source_compute_ssh="${SOURCE_COMPUTE_SSH_TARGET:-${expected_compute_host}}"
target_compute_ssh="${TARGET_COMPUTE_SSH_TARGET:-${compute2_host}}"
client_guest_host="${CLIENT_GUEST_HOST:-client-guest}"
backend_guest_host="${BACKEND_GUEST_HOST:-backend-guest}"
action_driver="${VNET_E2E_ACTION_DRIVER:-}"
execution_mode="real"
[[ -z "${action_driver}" ]] || execution_mode="test_driver"
skip_shared_preflight="${VNET_E2E_SKIP_SHARED_PREFLIGHT:-0}"
deploy_artifacts="${DEPLOY_ARTIFACTS:-1}"
require_netmig_tc="${REQUIRE_NETMIG_TC:-1}"
preflight_only="${PREFLIGHT_ONLY:-0}"
cleanup_audit_only="${CLEANUP_AUDIT_ONLY:-0}"
migration_mode="${MIGRATION_MODE:-disabled}"
migration_timeout="${MIGRATION_TIMEOUT:-900}"
migration_poll_interval="${MIGRATION_POLL_INTERVAL:-2}"
migration_transition_timeout="${MIGRATION_TRANSITION_TIMEOUT:-120}"
migration_wait_outer_timeout="${MIGRATION_WAIT_OUTER_TIMEOUT:-180}"
migration_command_timeout="${MIGRATION_COMMAND_TIMEOUT:-30}"
continuity_interval="${CONTINUITY_INTERVAL:-0.1}"
continuity_command_timeout="${CONTINUITY_COMMAND_TIMEOUT:-5}"
continuity_stop_timeout="${CONTINUITY_STOP_TIMEOUT:-15}"
continuity_min_samples="${CONTINUITY_MIN_SAMPLES:-5}"
continuity_max_duration="${CONTINUITY_MAX_DURATION:-2400}"
remote_command_timeout="${REMOTE_COMMAND_TIMEOUT:-30}"
probe_timeout="${PROBE_TIMEOUT:-5}"
deployment_timeout="${DEPLOYMENT_TIMEOUT:-60}"
attach_timeout="${ATTACH_TIMEOUT:-90}"
shared_preflight_timeout="${SHARED_PREFLIGHT_TIMEOUT:-15}"

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
deploy_profile="${DEPLOY_PROFILE:-shuka1-p1}"
[[ "${deploy_profile}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || {
  echo "DEPLOY_PROFILE contains unsupported characters" >&2
  exit 2
}
profile_dir="${accel_dir}/deploy/lab/${deploy_profile}"
profile_rel="linux_accel/deploy/lab/${deploy_profile}"
profile_remote="/opt/vnet-dataplane/${profile_rel}"

coordinator_script="${accel_dir}/agent/openstack_epoch_coordinator.py"
migration_script="${accel_dir}/bench/openstack_migration_leg.py"
continuity_script="${accel_dir}/bench/migration_continuity_probe.py"
shared_preflight_script="${accel_dir}/bench/openstack_shared_cluster_preflight.py"
shared_inventory="${SHARED_CLUSTER_INVENTORY:-}"
shared_ssh_identity="${SHARED_SSH_IDENTITY_FILE:-}"
host_agent_script="${accel_dir}/agent/openstack_dataplane_agent.py"
coordinator_config="/etc/vnet-dataplane-agent/coordinator.json"
desired_mode_file="/run/vnet-dataplane-metrics-controller/desired-mode.json"
coordinator_state_file="/var/lib/vnet-dataplane-epoch/state.json"
coordinator_audit_log="/var/log/vnet-dataplane-epoch/audit.jsonl"
host_agent_state_file="/run/vnet-dataplane-agent/state.json"
host_agent_audit_log="/var/log/vnet-dataplane-agent/audit.jsonl"
continuity_remote_root="/var/log/vnet-dataplane-continuity"
continuity_run_id="${VNET_CONTINUITY_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

coordinator_unit="${COORDINATOR_UNIT:-vnet-dataplane-epoch-coordinator.service}"
metrics_unit="${METRICS_UNIT:-vnet-dataplane-metrics-controller.service}"
host_agent_unit="${HOST_AGENT_UNIT:-vnet-dataplane-agent.service}"
guest_agent_unit="${GUEST_AGENT_UNIT:-vnet-dataplane-guest-endpoint.service}"
dns_backend_unit="${DNS_BACKEND_UNIT:-vnet-lab-dns-backend.service}"
grpc_backend_unit="${GRPC_BACKEND_UNIT:-vnet-lab-grpc-backend.service}"

client_tap="${CLIENT_HOST_INTERFACE:-tap${client_port_id:0:11}}"
backend_tap="${BACKEND_HOST_INTERFACE:-tap${backend_port_id:0:11}}"
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
migration_started=0
migration_roundtrip_completed=false
migration_recovery_attempted=false
migration_recovery_completed=false
backend_current_host="${expected_compute_host}"
continuity_active=0
continuity_phase=""
continuity_unit=""
continuity_remote_dir=""
metrics_invocation_id=""

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
for timeout_name in remote_command_timeout probe_timeout deployment_timeout attach_timeout shared_preflight_timeout; do
  timeout_value="${!timeout_name}"
  [[ "${timeout_value}" =~ ^[1-9][0-9]*$ ]] || {
    echo "${timeout_name} must be a positive integer" >&2
    exit 2
  }
done
for timeout_name in migration_timeout migration_poll_interval migration_transition_timeout migration_wait_outer_timeout migration_command_timeout; do
  timeout_value="${!timeout_name}"
  [[ "${timeout_value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "${timeout_name} must be positive" >&2
    exit 2
  }
  "${python_bin}" - "${timeout_name}" "${timeout_value}" <<'PY'
import sys

if float(sys.argv[2]) <= 0:
    raise SystemExit(f"{sys.argv[1]} must be positive")
PY
done
"${python_bin}" - "${migration_transition_timeout}" \
  "${migration_wait_outer_timeout}" "${migration_timeout}" \
  "${migration_command_timeout}" <<'PY'
import sys

transition, outer, total, command = map(float, sys.argv[1:])
if outer <= transition:
    raise SystemExit("MIGRATION_WAIT_OUTER_TIMEOUT must exceed MIGRATION_TRANSITION_TIMEOUT")
if command > total:
    raise SystemExit("MIGRATION_COMMAND_TIMEOUT must not exceed MIGRATION_TIMEOUT")
PY
for numeric_name in continuity_interval continuity_command_timeout continuity_stop_timeout continuity_max_duration; do
  numeric_value="${!numeric_name}"
  [[ "${numeric_value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "${numeric_name} must be positive" >&2
    exit 2
  }
  "${python_bin}" - "${numeric_name}" "${numeric_value}" <<'PY'
import sys

if float(sys.argv[2]) <= 0:
    raise SystemExit(f"{sys.argv[1]} must be positive")
PY
done
"${python_bin}" - "${continuity_command_timeout}" "${continuity_stop_timeout}" \
  "${remote_command_timeout}" <<'PY'
import sys

command_timeout, stop_timeout, remote_timeout = map(float, sys.argv[1:])
if stop_timeout <= command_timeout:
    raise SystemExit("CONTINUITY_STOP_TIMEOUT must exceed CONTINUITY_COMMAND_TIMEOUT")
if remote_timeout <= stop_timeout:
    raise SystemExit("REMOTE_COMMAND_TIMEOUT must exceed CONTINUITY_STOP_TIMEOUT")
PY
[[ "${continuity_min_samples}" =~ ^[1-9][0-9]*$ ]] || {
  echo "continuity_min_samples must be a positive integer" >&2
  exit 2
}
[[ "${continuity_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || {
  echo "VNET_CONTINUITY_RUN_ID contains unsupported characters" >&2
  exit 2
}
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
[[ "${migration_mode}" == disabled || "${migration_mode}" == roundtrip ]] || {
  echo "MIGRATION_MODE must be disabled or roundtrip" >&2
  exit 2
}
[[ "${source_compute_remote}" == 0 || "${source_compute_remote}" == 1 ]] || {
  echo "SOURCE_COMPUTE_REMOTE must be 0 or 1" >&2
  exit 2
}
[[ "${skip_shared_preflight}" == 0 || "${skip_shared_preflight}" == 1 ]] || {
  echo "VNET_E2E_SKIP_SHARED_PREFLIGHT must be 0 or 1" >&2
  exit 2
}
if [[ "${skip_shared_preflight}" == 1 && -z "${action_driver}" ]]; then
  echo "VNET_E2E_SKIP_SHARED_PREFLIGHT is test-driver-only" >&2
  exit 2
fi
if [[ "${source_compute_remote}" == 1 ]]; then
  for required_name in SOURCE_COMPUTE_SSH_TARGET TARGET_COMPUTE_SSH_TARGET \
    CLIENT_HOST_INTERFACE BACKEND_HOST_INTERFACE DEPLOY_PROFILE \
    VNET_KNOWN_HOSTS REQUIRE_NETMIG_TC SHARED_CLUSTER_INVENTORY \
    SHARED_SSH_IDENTITY_FILE; do
    required_value="${!required_name-}"
    [[ -n "${required_value}" ]] || {
      echo "remote source Compute requires explicit ${required_name}" >&2
      exit 2
    }
  done
  [[ "${deploy_artifacts}" == 0 ]] || {
    echo "remote source Compute requires pre-staged artifacts (set DEPLOY_ARTIFACTS=0); use the shared-cluster stage deployer" >&2
    exit 2
  }
fi
for interface_name in client_tap backend_tap; do
  interface_value="${!interface_name}"
  [[ "${interface_value}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$ ]] || {
    echo "${interface_name} is not a safe Linux interface name" >&2
    exit 2
  }
done
for unit_name in coordinator_unit metrics_unit host_agent_unit guest_agent_unit \
  dns_backend_unit grpc_backend_unit; do
  unit_value="${!unit_name}"
  [[ "${unit_value}" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,126}[.]service$ ]] || {
    echo "${unit_name} is not a safe systemd service name" >&2
    exit 2
  }
done
(( preflight_only + cleanup_audit_only <= 1 )) || {
  echo "PREFLIGHT_ONLY and CLEANUP_AUDIT_ONLY are mutually exclusive" >&2
  exit 2
}
[[ "${client_server_id}" != "${backend_server_id}" &&
   "${client_port_id}" != "${backend_port_id}" ]] || {
  echo "client and backend OpenStack identities must be distinct" >&2
  exit 2
}
[[ "${expected_compute_host}" != "${compute2_host}" ]] || {
  echo "source and target Nova hosts must be distinct" >&2
  exit 2
}
[[ "${source_compute_ssh}" != "${target_compute_ssh}" ]] || {
  echo "source and target SSH destinations must be distinct" >&2
  exit 2
}
[[ "${client_guest_host}" != "${backend_guest_host}" ]] || {
  echo "client and backend guest SSH destinations must be distinct" >&2
  exit 2
}
for uuid_name in client_server_id client_port_id backend_server_id backend_port_id; do
  uuid_value="${!uuid_name}"
  [[ "${uuid_value}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
    echo "${uuid_name} must be a canonical lowercase UUID" >&2
    exit 2
  }
done
for host_name in expected_compute_host compute2_host source_compute_ssh \
  target_compute_ssh client_guest_host backend_guest_host; do
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

remote_exec_timeout() {
  local command_timeout="$1" host="$2"
  shift 2
  "${timeout_bin}" --signal=TERM "${command_timeout}" \
    "${ssh_bin}" -n "${ssh_options[@]}" "${host}" "$@"
}

remote_sudo_timeout() {
  local command_timeout="$1" host="$2"
  shift 2
  remote_exec_timeout "${command_timeout}" "${host}" /usr/bin/sudo -n "$@"
}

remote_sudo_probe() {
  local host="$1"
  shift
  remote_probe "${host}" /usr/bin/sudo -n "$@"
}

compute_ssh_target() {
  case "$1" in
    "${expected_compute_host}")
      printf '%s\n' "${source_compute_ssh}"
      ;;
    "${compute2_host}")
      printf '%s\n' "${target_compute_ssh}"
      ;;
    *)
      echo "unknown compute host: $1" >&2
      return 2
      ;;
  esac
}

remote_service_target() {
  case "$1" in
    "${expected_compute_host}"|"${compute2_host}")
      compute_ssh_target "$1"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

host_sudo() {
  local host="$1"
  shift
  if [[ "${source_compute_remote}" == 0 &&
        "${host}" == "${expected_compute_host}" ]]; then
    local_sudo "$@"
  else
    remote_sudo "$(compute_ssh_target "${host}")" "$@"
  fi
}

host_sudo_probe() {
  local host="$1"
  shift
  if [[ "${source_compute_remote}" == 0 &&
        "${host}" == "${expected_compute_host}" ]]; then
    local_sudo "$@"
  else
    remote_sudo_probe "$(compute_ssh_target "${host}")" "$@"
  fi
}

host_sudo_timeout() {
  local command_timeout="$1" host="$2"
  shift 2
  if [[ "${source_compute_remote}" == 0 &&
        "${host}" == "${expected_compute_host}" ]]; then
    "${timeout_bin}" --signal=TERM "${command_timeout}" \
      "${sudo_bin}" -n "$@"
  else
    remote_sudo_timeout "${command_timeout}" \
      "$(compute_ssh_target "${host}")" "$@"
  fi
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
    "${profile_dir}/endpoint-client.json" \
    "${profile_dir}/endpoint-server.json" \
    "${profile_dir}/coordinator.json" \
    "${profile_dir}/metrics-bridge.json" \
    "${profile_dir}/dns-cache.policy" \
    "${profile_dir}/vnet-lab-dns-backend.service" \
    "${profile_dir}/vnet-lab-grpc-backend.service" \
    "${client_server_id}" "${client_port_id}" \
    "${backend_server_id}" "${backend_port_id}" \
    "${client_ip}" "${backend_ip}" \
    "${client_guest_host}" "${backend_guest_host}" "${compute2_host}" \
    "${expected_compute_host}" "${source_compute_ssh}" \
    "${target_compute_ssh}" "${source_compute_remote}" <<'PY'
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
    source_compute_ssh,
    target_compute_ssh,
    source_compute_remote,
) = sys.argv[1:]
source_compute_remote = source_compute_remote == "1"

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
        "compute_port",
        "server",
        {"grpc"},
    ),
    "compute2-backend-caches": (
        backend_server_id,
        backend_port_id,
        compute2_host,
        "backend-host-caches",
        "compute_port",
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

for name in ("master-client-caches", "backend-host-caches"):
    publisher = publisher_by_name[name]
    command_text = json.dumps(publisher.get("command", []), sort_keys=True)
    if source_compute_remote:
        if (
            publisher.get("ssh_destination") != source_compute_ssh
            or source_compute_ssh not in command_text
        ):
            raise SystemExit(f"source publisher SSH transport is misbound: {name}")
    elif publisher.get("ssh_destination") is not None or source_compute_ssh in command_text:
        raise SystemExit(f"local source publisher unexpectedly uses SSH: {name}")
for name in ("compute2-client-caches", "compute2-backend-caches"):
    publisher = publisher_by_name[name]
    command_text = json.dumps(publisher.get("command", []), sort_keys=True)
    if target_compute_ssh not in command_text:
        raise SystemExit(f"target publisher SSH transport is misbound: {name}")
    configured = publisher.get("ssh_destination")
    if target_compute_ssh != compute2_host and configured != target_compute_ssh:
        raise SystemExit(f"target publisher lacks explicit SSH destination: {name}")

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
    "compute2-grpc-observer-monitor": ("grpc_metrics", "server", backend_port_id, compute2_host),
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

for name in (
    "master-dns-client-monitor",
    "master-grpc-client-monitor",
    "master-grpc-observer-monitor",
):
    source = source_by_name[name]
    source_text = json.dumps(source.get("command", []), sort_keys=True)
    if source_compute_remote:
        if "command" not in source or source_compute_ssh not in source_text:
            raise SystemExit(f"source metrics SSH transport is misbound: {name}")
    elif "path" not in source or "command" in source:
        raise SystemExit(f"local source metrics transport is invalid: {name}")
for name in (
    "compute2-dns-client-monitor",
    "compute2-grpc-client-monitor",
    "compute2-grpc-observer-monitor",
):
    source_text = json.dumps(source_by_name[name].get("command", []), sort_keys=True)
    if target_compute_ssh not in source_text:
        raise SystemExit(f"target metrics SSH transport is misbound: {name}")

state_sources = coordinator.get("state_sources", [])
if not isinstance(state_sources, list) or any(
    not isinstance(item, dict) for item in state_sources
):
    raise SystemExit("coordinator state sources are invalid")
state_by_name = {item.get("name"): item for item in state_sources}
if len(state_by_name) != len(state_sources):
    raise SystemExit("coordinator state source names are duplicated")
for name in ("master", "compute2", "client-guest", "backend-guest"):
    if name not in state_by_name:
        raise SystemExit(f"coordinator state source is missing: {name}")
source_state = state_by_name["master"]
source_state_text = json.dumps(source_state.get("command", []), sort_keys=True)
if source_compute_remote:
    if "command" not in source_state or source_compute_ssh not in source_state_text:
        raise SystemExit("source Agent state SSH transport is misbound")
elif "path" not in source_state or "command" in source_state:
    raise SystemExit("local source Agent state transport is invalid")
if target_compute_ssh not in json.dumps(
    state_by_name["compute2"].get("command", []), sort_keys=True
):
    raise SystemExit("target Agent state SSH transport is misbound")
if client_host not in json.dumps(
    state_by_name["client-guest"].get("command", []), sort_keys=True
):
    raise SystemExit("client guest state SSH transport is misbound")
if backend_host not in json.dumps(
    state_by_name["backend-guest"].get("command", []), sort_keys=True
):
    raise SystemExit("backend guest state SSH transport is misbound")

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
    "${migration_script}" \
    "${continuity_script}" \
    "${shared_preflight_script}" \
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
    "${profile_dir}/coordinator.env" \
    "${profile_dir}/coordinator.json" \
    "${profile_dir}/metrics-bridge.env" \
    "${profile_dir}/metrics-bridge.json" \
    "${profile_dir}/dns-cache.policy" \
    "${profile_dir}/endpoint-client.json" \
    "${profile_dir}/endpoint-server.json" \
    "${profile_dir}/grpc-cache.policy" \
    "${profile_dir}/guest-endpoint.env" \
    "${profile_dir}/vnet-dataplane.sudoers" \
    "${profile_dir}/vnet-lab-dns-backend.service" \
    "${profile_dir}/vnet-lab-grpc-backend.service" \
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
    "${profile_dir}/vnet-dataplane.sudoers"
  local deployment_hosts=(
    "${target_compute_ssh}"
    "${client_guest_host}"
    "${backend_guest_host}"
  )
  if [[ "${source_compute_remote}" == 1 ]]; then
    deployment_hosts+=("${source_compute_ssh}")
  fi
  for host in "${deployment_hosts[@]}"; do
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
      /opt/vnet-dataplane/linux_accel/bench \
      /opt/vnet-dataplane/linux_accel/build \
      /opt/vnet-dataplane/linux_accel/deploy \
      /opt/vnet-dataplane/linux_accel/deploy/lab \
      "${profile_remote}" \
      /opt/vnet-dataplane/linux_accel/deploy/systemd; do
      remote_sudo "${host}" /usr/bin/test ! -L "${path}"
    done
  done
  remote_sudo "${client_guest_host}" /usr/bin/test -x /usr/bin/systemd-run
  host_sudo "${expected_compute_host}" /usr/bin/cat \
    /etc/vnet-dataplane-agent/endpoints.json \
    >"${out_dir}/openstack/source-compute-endpoints.json"
  host_sudo "${compute2_host}" /usr/bin/cat \
    /etc/vnet-dataplane-agent/endpoints.json \
    >"${out_dir}/openstack/target-compute-endpoints.json"
  "${python_bin}" - \
    "${out_dir}/openstack/source-compute-endpoints.json" \
    "${out_dir}/openstack/target-compute-endpoints.json" \
    "${client_server_id}" "${backend_server_id}" \
    "${client_port_id}" "${backend_port_id}" "${backend_ip}" <<'PY'
import json
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if (
        not isinstance(value, dict)
        or value.get("schema_version") != 2
        or not isinstance(value.get("endpoints"), list)
    ):
        raise SystemExit(f"invalid compute endpoint config: {path}")
    return value


master = load(sys.argv[1])
compute2 = load(sys.argv[2])
client_server_id, backend_server_id, client_port_id, backend_port_id, backend_ip = (
    sys.argv[3:]
)
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
if client.get("port_ids") != [client_port_id]:
    raise SystemExit("client endpoint port allowlist does not match CLIENT_PORT_ID")
if backend.get("port_ids") != [backend_port_id]:
    raise SystemExit("backend endpoint port allowlist does not match BACKEND_PORT_ID")
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
    remote_sudo "${target_compute_ssh}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/cache_policy_txn
    remote_sudo "${client_guest_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/openstack_grpc_harness
    remote_sudo "${backend_guest_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/dns_monitor
  fi
}

capture_tc_identity() {
  local host="$1"
  local tap="$2"
  local direction="$3"
  local handle="$4"
  local output="$5"
  local raw="${output%.json}.txt"
  host_sudo "${host}" /usr/sbin/tc filter show dev "${tap}" "${direction}" \
    >"${raw}"
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
  capture_tc_identity "${expected_compute_host}" "${client_tap}" ingress 0x65 \
    "${out_dir}/systemd/${client_tap}.netmig-ingress-before.json"
  capture_tc_identity "${expected_compute_host}" "${client_tap}" egress 0x66 \
    "${out_dir}/systemd/${client_tap}.netmig-egress-before.json"
  capture_tc_identity "${expected_compute_host}" "${backend_tap}" ingress 0x65 \
    "${out_dir}/systemd/${backend_tap}.netmig-ingress-before.json"
  capture_tc_identity "${expected_compute_host}" "${backend_tap}" egress 0x66 \
    "${out_dir}/systemd/${backend_tap}.netmig-egress-before.json"
}

bind_compute_config_to_fingerprints() {
  "${python_bin}" - \
    "${out_dir}/openstack/source-compute-endpoints.json" \
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
    item.get("server_id"): {
        "accel_role": item.get("accel_role"),
        "port_ids": item.get("port_ids"),
    }
    for item in config.get("endpoints", [])
    if isinstance(item, dict)
}
expected = {
    fingerprints["client"]["server_id"]: {
        "accel_role": "client",
        "port_ids": [fingerprints["client"]["port_id"]],
    },
    fingerprints["backend"]["server_id"]: {
        "accel_role": "observer",
        "port_ids": [fingerprints["backend"]["port_id"]],
    },
}
if configured != expected:
    raise SystemExit("compute config cannot be bound to the selected Neutron ports")
bindings = []
for role in ("client", "backend"):
    fingerprint = fingerprints[role]
    bindings.append(
        {
            "role": role,
            "accel_role": configured[fingerprint["server_id"]]["accel_role"],
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

run_shared_cluster_preflight() {
  [[ "${source_compute_remote}" == 1 ]] || return 0
  local report="${out_dir}/openstack/shared-cluster-preflight.json"
  "${python_bin}" "${shared_preflight_script}" \
    --inventory "${shared_inventory}" \
    --identity-file "${shared_ssh_identity}" \
    --output "${report}" \
    --timeout "${shared_preflight_timeout}" || return 1
  "${python_bin}" - \
    "${shared_preflight_script}" "${shared_inventory}" "${report}" \
    "${expected_compute_host}" "${compute2_host}" \
    "${source_compute_ssh}" "${target_compute_ssh}" \
    "${client_server_id}" "${backend_server_id}" \
    "${client_port_id}" "${backend_port_id}" \
    "${client_ip}" "${backend_ip}" \
    "${client_tap}" "${backend_tap}" <<'PY'
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

(
    module_path,
    inventory_path,
    report_path,
    source_host,
    target_host,
    source_ssh,
    target_ssh,
    client_server_id,
    backend_server_id,
    client_port_id,
    backend_port_id,
    client_ip,
    backend_ip,
    client_interface,
    backend_interface,
) = sys.argv[1:]

spec = importlib.util.spec_from_file_location("shared_preflight_binding", module_path)
if spec is None or spec.loader is None:
    raise SystemExit("shared preflight module cannot be loaded")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
finally:
    sys.modules.pop(spec.name, None)
inventory = module.load_inventory(Path(inventory_path))
report = json.loads(Path(report_path).read_text(encoding="utf-8"))
if (
    not isinstance(report, dict)
    or report.get("schema_version") != 1
    or report.get("status") != "allowed"
    or report.get("deploy_allowed") is not True
):
    raise SystemExit("shared preflight report is not an allowed schema-1 result")
gates = report.get("gates")
if not isinstance(gates, list) or not gates or any(
    not isinstance(item, dict) or item.get("passed") is not True for item in gates
):
    raise SystemExit("shared preflight report contains a failed or invalid gate")
canonical = json.dumps(
    inventory, sort_keys=True, separators=(",", ":"), ensure_ascii=True
).encode("utf-8")
expected_hash = hashlib.sha256(canonical).hexdigest()
if report.get("inventory", {}).get("sha256") != expected_hash:
    raise SystemExit("shared preflight report does not match the inventory")


def split_destination(value):
    if value.count("@") != 1:
        raise SystemExit("shared Compute SSH destination must be user@address")
    user, address = value.split("@", 1)
    if not user or not address:
        raise SystemExit("shared Compute SSH destination is incomplete")
    return user, address


source = inventory["roles"]["source"]
target = inventory["roles"]["target"]
if source["expected_hostname"] != source_host:
    raise SystemExit("shared inventory source Nova host differs from the runner")
if target["expected_hostname"] != target_host:
    raise SystemExit("shared inventory target Nova host differs from the runner")
for role, node, destination in (
    ("source", source, source_ssh),
    ("target", target, target_ssh),
):
    user, address = split_destination(destination)
    if (user, address) != (node["ssh_user"], node["address"]):
        raise SystemExit(f"shared inventory {role} SSH identity differs from the runner")
if set(inventory["allowed_server_ids"]) != {
    client_server_id,
    backend_server_id,
}:
    raise SystemExit("shared preflight resource ownership differs from the runner")
if set(inventory["allowed_port_ids"]) != {client_port_id, backend_port_id}:
    raise SystemExit("shared preflight port ownership differs from the runner")
if inventory["port_server_bindings"] != {
    client_port_id: client_server_id,
    backend_port_id: backend_server_id,
}:
    raise SystemExit("shared preflight port-to-server ownership differs from the runner")
if inventory["port_fixed_ipv4s"] != {
    client_port_id: client_ip,
    backend_port_id: backend_ip,
}:
    raise SystemExit("shared preflight fixed IP ownership differs from the runner")
expected_bindings = {
    client_port_id: client_interface,
    backend_port_id: backend_interface,
}
if source["required_port_bindings"] != expected_bindings:
    raise SystemExit("shared preflight source port bindings differ from the runner")
if set(source["required_tap_interfaces"]) != set(expected_bindings.values()):
    raise SystemExit("shared preflight source interfaces differ from the runner")
if target["required_port_bindings"] or target["required_tap_interfaces"]:
    raise SystemExit("shared preflight target must be unbound before migration")
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
    /opt/vnet-dataplane/linux_accel/bench \
    /opt/vnet-dataplane/linux_accel/build \
    /opt/vnet-dataplane/linux_accel/deploy \
    /opt/vnet-dataplane/linux_accel/deploy/lab \
    "${profile_remote}" \
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
    "${accel_dir}/bench" \
    "${accel_dir}/build" "${accel_dir}/deploy" \
    "${accel_dir}/deploy/lab" "${profile_dir}" \
    "${accel_dir}/deploy/systemd"
  local_sudo /usr/bin/chmod 0755 \
    "${repo_dir}" "${accel_dir}" "${accel_dir}/agent" \
    "${accel_dir}/bench" \
    "${accel_dir}/build" "${accel_dir}/deploy" \
    "${accel_dir}/deploy/lab" "${profile_dir}" \
    "${accel_dir}/deploy/systemd"
  local_sudo /usr/bin/chown root:root "${files[@]}"
  local_sudo /usr/bin/chmod go-w "${files[@]}"
  verify_local_secure_files "${files[@]}"
}

install_local_deployment() {
  if [[ "${source_compute_remote}" == 1 ]]; then
    local files=()
    mapfile -t files < <(required_deployment_files)
    verify_local_secure_files "${files[@]}"
  else
    secure_local_runtime_tree
  fi
  local controller_units=(
    "${accel_dir}/deploy/systemd/vnet-dataplane-metrics-controller.service" \
    "${accel_dir}/deploy/systemd/vnet-dataplane-epoch-coordinator.service" \
  )
  if [[ "${source_compute_remote}" == 0 ]]; then
    controller_units+=(
      "${accel_dir}/deploy/systemd/vnet-dataplane-bpffs.service"
      "${accel_dir}/deploy/systemd/vnet-dataplane-agent.service"
    )
  fi
  local_sudo /usr/bin/install -m 0644 "${controller_units[@]}" \
    /etc/systemd/system/
  local_sudo /usr/bin/install -d -o root -g root -m 0700 \
    /etc/vnet-dataplane-agent /etc/vnet-dataplane-metrics-controller
  local_sudo /usr/bin/install -m 0600 \
    "${profile_dir}/coordinator.env" \
    "${profile_dir}/coordinator.json" \
    /etc/vnet-dataplane-agent/
  local_sudo /usr/bin/install -m 0600 \
    "${profile_dir}/metrics-bridge.env" \
    "${profile_dir}/metrics-bridge.json" \
    /etc/vnet-dataplane-metrics-controller/
  for required in openstack.env agent.env endpoints.json; do
    local_sudo /usr/bin/test -r "/etc/vnet-dataplane-agent/${required}"
  done
  local_sudo /usr/bin/test -r "${known_hosts}"
  local_sudo /usr/bin/systemctl daemon-reload
}

install_remote_compute_deployment() {
  local host="$1"
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
  stream_tree "${host}" "${files[@]}"
  remote_sudo "${host}" /usr/bin/install -m 0644 \
    /opt/vnet-dataplane/linux_accel/deploy/systemd/vnet-dataplane-agent.service \
    /opt/vnet-dataplane/linux_accel/deploy/systemd/vnet-dataplane-bpffs.service \
    /etc/systemd/system/
  for required in openstack.env agent.env endpoints.json; do
    remote_sudo "${host}" /usr/bin/test -r \
      "/etc/vnet-dataplane-agent/${required}"
  done
  remote_sudo "${host}" /usr/bin/systemctl daemon-reload
}

install_guest_deployment() {
  local host="$1"
  local endpoint_file="$2"
  local install_backend_units="$3"
  local files=(
    linux_accel/agent/openstack_guest_endpoint_agent.py
    linux_accel/agent/openstack_metrics_bridge.py
    linux_accel/bench/migration_continuity_probe.py
    linux_accel/build/cache_policy_txn
    linux_accel/build/dns_cache_stats_reader
    linux_accel/build/dns_monitor
    linux_accel/build/dns_xdp_monitor.bpf.o
    linux_accel/build/grpc_fast_cache
    linux_accel/build/openstack_dns_harness
    linux_accel/build/openstack_grpc_harness
    "${profile_rel}/dns-cache.policy"
    "${profile_rel}/grpc-cache.policy"
    "${profile_rel}/guest-endpoint.env"
    "${profile_rel}/${endpoint_file}"
    "${profile_rel}/vnet-dataplane.sudoers"
    linux_accel/deploy/systemd/vnet-dataplane-bpffs.service
    linux_accel/deploy/systemd/vnet-dataplane-guest-endpoint.service
  )
  if [[ "${install_backend_units}" == 1 ]]; then
    files+=(
      "${profile_rel}/vnet-lab-dns-backend.service"
      "${profile_rel}/vnet-lab-grpc-backend.service"
    )
  fi
  stream_tree "${host}" "${files[@]}"
  remote_sudo "${host}" /usr/bin/install -d -o root -g root -m 0700 \
    /etc/vnet-dataplane-guest
  remote_sudo "${host}" /usr/bin/install -m 0600 \
    "${profile_remote}/guest-endpoint.env" \
    /etc/vnet-dataplane-guest/guest-endpoint.env
  remote_sudo "${host}" /usr/bin/install -m 0600 \
    "${profile_remote}/${endpoint_file}" \
    /etc/vnet-dataplane-guest/endpoint.json
  remote_sudo "${host}" /usr/bin/install -m 0644 \
    "${profile_remote}/dns-cache.policy" \
    "${profile_remote}/grpc-cache.policy" \
    /etc/vnet-dataplane-guest/
  remote_sudo "${host}" /usr/bin/install -m 0644 \
    /opt/vnet-dataplane/linux_accel/deploy/systemd/vnet-dataplane-bpffs.service \
    /opt/vnet-dataplane/linux_accel/deploy/systemd/vnet-dataplane-guest-endpoint.service \
    /etc/systemd/system/
  remote_sudo "${host}" /usr/sbin/visudo -cf \
    "${profile_remote}/vnet-dataplane.sudoers"
  remote_sudo "${host}" /usr/bin/install -o root -g root -m 0440 \
    "${profile_remote}/vnet-dataplane.sudoers" \
    /etc/sudoers.d/vnet-dataplane
  remote_sudo "${host}" /usr/sbin/visudo -cf \
    /etc/sudoers.d/vnet-dataplane
  if [[ "${install_backend_units}" == 1 ]]; then
    remote_sudo "${host}" /usr/bin/install -m 0644 \
      "${profile_remote}/vnet-lab-dns-backend.service" \
      "${profile_remote}/vnet-lab-grpc-backend.service" \
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
    "${migration_script}"
    "${continuity_script}"
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
    install_remote_compute_deployment "${target_compute_ssh}"
    if [[ "${source_compute_remote}" == 1 ]]; then
      install_remote_compute_deployment "${source_compute_ssh}"
    fi
    install_guest_deployment "${client_guest_host}" endpoint-client.json 0
    install_guest_deployment "${backend_guest_host}" endpoint-server.json 1
  else
    local_sudo /usr/bin/test -r /etc/vnet-dataplane-agent/coordinator.json
    local_sudo /usr/bin/test -r /etc/vnet-dataplane-metrics-controller/metrics-bridge.json
    remote_sudo "${target_compute_ssh}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/cache_policy_txn
    remote_sudo "${client_guest_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/openstack_grpc_harness
    remote_sudo "${client_guest_host}" /usr/bin/test -r \
      /opt/vnet-dataplane/linux_accel/bench/migration_continuity_probe.py
    remote_sudo "${backend_guest_host}" /usr/bin/test -x \
      /opt/vnet-dataplane/linux_accel/build/dns_monitor
  fi
}

capture_running_stack_evidence() {
  host_sudo "${expected_compute_host}" /usr/bin/python3 \
    /opt/vnet-dataplane/linux_accel/agent/openstack_dataplane_agent.py health \
    --state-file /run/vnet-dataplane-agent/state.json \
    --server-id "${client_server_id}" --server-id "${backend_server_id}" \
    --max-age-seconds 20 \
    >"${out_dir}/systemd/source-compute-agent-health.json" || return 1
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
  host_sudo "${expected_compute_host}" /usr/bin/cat \
    /run/vnet-dataplane-agent/state.json \
    >"${out_dir}/systemd/source-compute-agent-state.json" || return 1
  host_sudo "${compute2_host}" /usr/bin/cat \
    /run/vnet-dataplane-agent/state.json \
    >"${out_dir}/systemd/target-compute-agent-state.json" || return 1
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
  host_sudo "${expected_compute_host}" /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}/dns/cache_runtime_control" \
    >"${out_dir}/systemd/source-compute-client-dns-runtime-map.json" || return 1
  host_sudo "${expected_compute_host}" /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}/grpc/cache_runtime_control" \
    >"${out_dir}/systemd/source-compute-client-grpc-runtime-map.json" || return 1
  host_sudo "${expected_compute_host}" /usr/sbin/bpftool -j map show pinned \
    "/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}/grpc/cache_runtime_control" \
    >"${out_dir}/systemd/source-compute-backend-grpc-runtime-map.json" || return 1
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
    "${out_dir}/systemd/source-compute-agent-state.json" \
    "${out_dir}/systemd/target-compute-agent-state.json" \
    "${out_dir}/systemd/client-guest-state.json" \
    "${out_dir}/systemd/backend-guest-state.json" \
    "${out_dir}/systemd/client-guest-ens3.json" \
    "${out_dir}/systemd/backend-guest-ens3.json" \
    "${out_dir}/systemd/source-compute-client-dns-runtime-map.json" \
    "${out_dir}/systemd/source-compute-client-grpc-runtime-map.json" \
    "${out_dir}/systemd/source-compute-backend-grpc-runtime-map.json" \
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
import time
from pathlib import Path


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


fingerprints = load(sys.argv[1])
source = load(sys.argv[2])
target = load(sys.argv[3])
client_state = load(sys.argv[4])
backend_state = load(sys.argv[5])
client_link = load(sys.argv[6])
backend_link = load(sys.argv[7])
map_documents = [load(path) for path in sys.argv[8:14]]
(
    expected_host,
    target_host,
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
if set(source.get("server_ids", [])) != expected_servers:
    raise SystemExit("source Compute state server identities do not match the run")
if source.get("local_host") != expected_host:
    raise SystemExit("source Compute local_host does not match Neutron binding")
attachments = source.get("attachments")
if not isinstance(attachments, dict) or set(attachments) != {
    client_port_id,
    backend_port_id,
}:
    raise SystemExit("source Compute state does not contain two independent attachments")
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
        raise SystemExit(f"source Compute attachment binding is stale: {port_id}")
    if not isinstance(binding.get("ifindex"), int) or binding["ifindex"] <= 0:
        raise SystemExit(f"source Compute attachment ifindex is invalid: {port_id}")
    if record.get("healthy") is not True or record.get("missing_pins") != []:
        raise SystemExit(f"source Compute attachment is not healthy: {port_id}")
    if record.get("hook_ownership_verified") is not True:
        raise SystemExit(f"source Compute hook ownership is not verified: {port_id}")
    expected_programs = record.get("program_ids")
    current_programs = record.get("current_program_ids")
    if not isinstance(expected_programs, dict) or current_programs != expected_programs:
        raise SystemExit(f"source Compute hook program IDs changed: {port_id}")
    for name, program_id in expected_programs.items():
        if name == "dns_xdp" and program_id is None:
            continue
        if not isinstance(program_id, int) or program_id <= 0:
            raise SystemExit(f"source Compute hook program ID is invalid: {port_id}/{name}")

if set(target.get("server_ids", [])) != expected_servers:
    raise SystemExit("target Compute state server identities do not match the run")
if target.get("local_host") != target_host:
    raise SystemExit("target Compute state has an unexpected local_host")
target_attachments = target.get("attachments")
if not isinstance(target_attachments, dict) or any(
    port_id in target_attachments for port_id in (client_port_id, backend_port_id)
):
    raise SystemExit("target Compute unexpectedly owns a source-bound attachment")
updated_ms = target.get("updated_ms")
if isinstance(updated_ms, bool) or not isinstance(updated_ms, int):
    raise SystemExit("target Compute state has no integer updated_ms")
if abs(int(time.time() * 1000) - updated_ms) > 20_000:
    raise SystemExit("target Compute state is stale or from the future")
target_snapshot = target.get("snapshot_consistency")
if not isinstance(target_snapshot, dict) or {
    "status": target_snapshot.get("status"),
    "error": target_snapshot.get("error"),
} != {"status": "consistent", "error": None}:
    raise SystemExit("target Compute discovery snapshot is not consistent")
target_health = target.get("health")
if not isinstance(target_health, dict) or target_health.get("status") != "idle":
    raise SystemExit("target Compute Agent is not in a fresh idle state")
for field in (
    "healthy_port_ids",
    "transition_port_ids",
    "degraded_port_ids",
):
    if target_health.get(field) != []:
        raise SystemExit(f"target Compute Agent has unexpected {field}")

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
        "source_client_dns",
        expected_host,
        f"/sys/fs/bpf/vnet-dataplane-agent/{client_port_id}/dns/cache_runtime_control",
    ),
    (
        "source_client_grpc",
        expected_host,
        f"/sys/fs/bpf/vnet-dataplane-agent/{client_port_id}/grpc/cache_runtime_control",
    ),
    (
        "source_backend_grpc",
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
source_ids = {
    identities[label]["id"]
    for label in ("source_client_dns", "source_client_grpc", "source_backend_grpc")
}
if len(source_ids) != 3:
    raise SystemExit("source Compute runtime maps are not independent")
if identities["source_client_grpc"]["id"] == identities["source_backend_grpc"]["id"]:
    raise SystemExit("source Compute client/backend gRPC runtime maps are not independent")
if identities["backend_guest_dns"]["id"] == identities["backend_guest_grpc"]["id"]:
    raise SystemExit("backend guest DNS/gRPC runtime maps are not independent")
map_output.write_text(
    json.dumps(
        {
            "schema_version": 1,
            "maps": identities,
            "checks": {
                "source_compute_maps_independent": True,
                "source_compute_client_backend_grpc_independent": True,
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
    if host_sudo_probe "${expected_compute_host}" /usr/bin/systemctl is-active --quiet "${host_agent_unit}" &&
       host_sudo_probe "${compute2_host}" /usr/bin/systemctl is-active --quiet "${host_agent_unit}" &&
       remote_sudo_probe "${client_guest_host}" /usr/bin/systemctl is-active --quiet "${guest_agent_unit}" &&
       remote_sudo_probe "${backend_guest_host}" /usr/bin/systemctl is-active --quiet "${guest_agent_unit}" &&
       host_sudo_probe "${expected_compute_host}" /usr/bin/grep -q "${client_port_id}" /run/vnet-dataplane-agent/state.json &&
       host_sudo_probe "${expected_compute_host}" /usr/bin/grep -q "${backend_port_id}" /run/vnet-dataplane-agent/state.json &&
       host_sudo_probe "${expected_compute_host}" /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}/dns/cache_runtime_control" &&
       host_sudo_probe "${expected_compute_host}" /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}/grpc/cache_runtime_control" &&
       host_sudo_probe "${expected_compute_host}" /usr/bin/test -e "/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}/grpc/cache_runtime_control" &&
       host_sudo_probe "${expected_compute_host}" /usr/bin/python3 /opt/vnet-dataplane/linux_accel/agent/openstack_dataplane_agent.py health \
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
        client "127.0.0.1" 50053 "${requests}" "${warmup}" health-check
      ;;
    *)
      echo "unknown workload protocol: ${protocol}" >&2
      return 2
      ;;
  esac
}

run_migration_leg() {
  local phase="$1" server_id="$2" source_host="$3" target_host="$4"
  local evidence_dir="${out_dir}/migration/${phase}/openstack"
  mkdir -p "${evidence_dir}"
  "${python_bin}" "${migration_script}" \
    --phase "${phase}" \
    --server-id "${server_id}" \
    --port-id "${backend_port_id}" \
    --source-host "${source_host}" \
    --target-host "${target_host}" \
    --evidence-dir "${evidence_dir}" \
    --openstack-bin "${openstack_bin}" \
    --api-version 2.30 \
    --timeout "${migration_timeout}" \
    --command-timeout "${migration_command_timeout}" \
    --poll "${migration_poll_interval}"
}

capture_migration_baseline() {
  local phase="$1" source_host="$2" target_host="$3" after_epoch="$4"
  local leg_dir="${out_dir}/migration/${phase}"
  local source_state="${leg_dir}/source-agent-state-before.json"
  local target_state="${leg_dir}/target-agent-state-before.json"
  local source_map="${leg_dir}/source-runtime-map-before.json"
  local server_json="${leg_dir}/backend-server-before.json"
  local port_json="${leg_dir}/backend-port-before.json"
  local pin_path="/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}/grpc/cache_runtime_control"
  local coordinator_cursor source_cursor target_cursor
  mkdir -p "${leg_dir}"

  coordinator_cursor="$(local_sudo /usr/bin/stat -Lc '%d:%i:%s' \
    "${coordinator_audit_log}")" || return 1
  source_cursor="$(host_sudo "${source_host}" /usr/bin/stat -Lc '%d:%i:%s' \
    "${host_agent_audit_log}")" || return 1
  target_cursor="$(host_sudo "${target_host}" /usr/bin/stat -Lc '%d:%i:%s' \
    "${host_agent_audit_log}")" || return 1
  for cursor in "${coordinator_cursor}" "${source_cursor}" "${target_cursor}"; do
    [[ "${cursor}" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || {
      echo "migration audit cursor is invalid: ${cursor}" >&2
      return 1
    }
  done

  host_sudo "${source_host}" /usr/bin/cat "${host_agent_state_file}" \
    >"${source_state}" || return 1
  host_sudo "${target_host}" /usr/bin/cat "${host_agent_state_file}" \
    >"${target_state}" || return 1
  host_sudo "${source_host}" /usr/sbin/bpftool -j map show pinned \
    "${pin_path}" >"${source_map}" || return 1
  if host_sudo_probe "${target_host}" /usr/bin/test -e "${pin_path}"; then
    echo "target host already contains the backend runtime pin before migration" >&2
    return 1
  fi
  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${openstack_bin}" server show "${backend_server_id}" -f json \
    >"${server_json}" || return 1
  "${timeout_bin}" --signal=TERM "${remote_command_timeout}" \
    "${openstack_bin}" port show "${backend_port_id}" -f json \
    >"${port_json}" || return 1

  "${python_bin}" - \
    "${source_state}" "${target_state}" "${source_map}" \
    "${server_json}" "${port_json}" \
    "${out_dir}/openstack/fingerprints.json" \
    "${phase}" "${source_host}" "${target_host}" "${after_epoch}" \
    "${coordinator_cursor}" "${source_cursor}" "${target_cursor}" \
    "${backend_server_id}" "${backend_port_id}" "${pin_path}" <<'PY'
import json
import re
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, (dict, list)):
        raise SystemExit(f"invalid JSON document: {path}")
    return value


def normalized(value):
    return re.sub(r"[^a-z0-9]+", "_", str(value).lower()).strip("_")


def field(value, *names):
    fields = {normalized(key): item for key, item in value.items()}
    for name in names:
        key = normalized(name)
        if key in fields:
            return fields[key]
    raise SystemExit(f"missing OpenStack field: {names}")


source_state = load(sys.argv[1])
target_state = load(sys.argv[2])
source_map = load(sys.argv[3])
server = load(sys.argv[4])
port = load(sys.argv[5])
fingerprints = load(sys.argv[6])
phase, source_host, target_host = sys.argv[7:10]
after_epoch = int(sys.argv[10])
cursor_values = sys.argv[11:14]
server_id, port_id, pin_path = sys.argv[14:17]

source_attachments = source_state.get("attachments")
target_attachments = target_state.get("attachments")
if not isinstance(source_attachments, dict) or port_id not in source_attachments:
    raise SystemExit("source Agent does not own the backend before migration")
if not isinstance(target_attachments, dict) or port_id in target_attachments:
    raise SystemExit("target Agent already owns the backend before migration")
record = source_attachments[port_id]
binding = record.get("binding") if isinstance(record, dict) else None
if not isinstance(binding, dict) or {
    "server_id": binding.get("server_id"),
    "port_id": binding.get("port_id"),
    "host": str(binding.get("host", "")).split(".", 1)[0],
} != {"server_id": server_id, "port_id": port_id, "host": source_host}:
    raise SystemExit("source Agent binding does not match the migration source")
if (
    record.get("healthy") is not True
    or record.get("missing_pins") != []
    or record.get("hook_ownership_verified") is not True
    or record.get("program_ids") != record.get("current_program_ids")
):
    raise SystemExit("source Agent attachment is not healthy before migration")

map_value = source_map[0] if isinstance(source_map, list) and len(source_map) == 1 else source_map
if not isinstance(map_value, dict) or not isinstance(map_value.get("id"), int):
    raise SystemExit("source runtime map identity is invalid")
if str(field(server, "id")) != server_id or str(field(server, "status")).upper() != "ACTIVE":
    raise SystemExit("backend server identity/status changed before migration")
if str(field(server, "OS-EXT-SRV-ATTR:host", "host")).split(".", 1)[0] != source_host:
    raise SystemExit("backend server is not on the declared source host")
if str(field(port, "id")) != port_id or str(field(port, "device_id")) != server_id:
    raise SystemExit("backend Neutron port identity changed before migration")
if str(field(port, "status")).upper() != "ACTIVE":
    raise SystemExit("backend Neutron port is not ACTIVE before migration")
if str(field(port, "binding_host_id", "binding:host_id")).split(".", 1)[0] != source_host:
    raise SystemExit("backend Neutron port is not bound to the source host")
if str(field(port, "mac_address")).lower() != fingerprints["backend"]["mac"]:
    raise SystemExit("backend Neutron MAC changed before migration")


def cursor(value):
    device, inode, offset = (int(item) for item in value.split(":"))
    return {"device": device, "inode": inode, "offset": offset}


result = {
    "schema": 1,
    "phase": phase,
    "source_host": source_host,
    "target_host": target_host,
    "after_epoch": after_epoch,
    "coordinator": cursor(cursor_values[0]),
    "source_agent": cursor(cursor_values[1]),
    "target_agent": cursor(cursor_values[2]),
    "source_runtime_map": {"host": source_host, "path": pin_path, "id": map_value["id"]},
    "target_pin_present": False,
    "topology": {"server_id": server_id, "port_id": port_id, "mac": fingerprints["backend"]["mac"]},
}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
}

wait_migration_transition() {
  local phase="$1" source_host="$2" target_host="$3" after_epoch="$4"
  local baseline="${out_dir}/migration/${phase}/baseline.json"
  local cursor_values result range_values start end count
  cursor_values="$("${python_bin}" - "${baseline}" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))["coordinator"]
print(value["device"], value["inode"], value["offset"])
PY
)" || return 1
  read -r audit_device audit_inode audit_offset <<<"${cursor_values}"
  result="$(local_sudo /usr/bin/python3 "${coordinator_script}" wait-transition \
    --config "${coordinator_config}" \
    --audit-log "${coordinator_audit_log}" \
    --after-offset "${audit_offset}" \
    --audit-device "${audit_device}" \
    --audit-inode "${audit_inode}" \
    --server-id "${backend_server_id}" \
    --port-id "${backend_port_id}" \
    --source-host "${source_host}" \
    --after-epoch "${after_epoch}" \
    --timeout "${migration_transition_timeout}" \
    --interval 0.05)" || return 1
  range_values="$("${python_bin}" -c \
    'import json,sys; v=json.loads(sys.argv[1]); print(v["matched_byte_start"],v["matched_byte_end"])' \
    "${result}")" || return 1
  read -r start end <<<"${range_values}"
  count=$((end - start))
  (( count > 0 )) || return 1
  local_sudo /usr/bin/dd if="${coordinator_audit_log}" bs=1 \
    skip="${start}" count="${count}" status=none \
    >"${out_dir}/migration/${phase}/coordinator-transition.jsonl" || return 1
  printf '%s\n' "${result}"
}

wait_migration_attachment() {
  local phase="$1" source_host="$2" target_host="$3"
  local leg_dir="${out_dir}/migration/${phase}"
  local baseline="${leg_dir}/baseline.json"
  local source_cursor target_cursor source_result target_result
  local source_range target_range source_start source_end target_start target_end
  local pin_root="/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}"
  local pin_path="${pin_root}/grpc/cache_runtime_control"
  source_cursor="$("${python_bin}" - "${baseline}" source_agent <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]
print(value["device"], value["inode"], value["offset"])
PY
)" || return 1
  target_cursor="$("${python_bin}" - "${baseline}" target_agent <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]
print(value["device"], value["inode"], value["offset"])
PY
)" || return 1
  read -r source_device source_inode source_offset <<<"${source_cursor}"
  read -r target_device target_inode target_offset <<<"${target_cursor}"

  source_result="$(host_sudo_timeout "${migration_wait_outer_timeout}" \
    "${source_host}" /usr/bin/python3 \
    "${host_agent_script}" wait-reconcile \
    --audit-log "${host_agent_audit_log}" \
    --after-offset "${source_offset}" --audit-device "${source_device}" \
    --audit-inode "${source_inode}" --server-id "${backend_server_id}" \
    --port-id "${backend_port_id}" --action detach \
    --reason binding_left_host --expected-host "${source_host}" \
    --timeout "${migration_transition_timeout}" --interval 0.05)" || return 1
  target_result="$(host_sudo_timeout "${migration_wait_outer_timeout}" \
    "${target_host}" /usr/bin/python3 \
    "${host_agent_script}" wait-reconcile \
    --audit-log "${host_agent_audit_log}" \
    --after-offset "${target_offset}" --audit-device "${target_device}" \
    --audit-inode "${target_inode}" --server-id "${backend_server_id}" \
    --port-id "${backend_port_id}" --action attach \
    --reason binding_local --expected-host "${target_host}" \
    --timeout "${migration_transition_timeout}" --interval 0.05)" || return 1
  source_range="$("${python_bin}" -c \
    'import json,sys; v=json.loads(sys.argv[1]); print(v["matched_byte_start"],v["matched_byte_end"])' \
    "${source_result}")" || return 1
  target_range="$("${python_bin}" -c \
    'import json,sys; v=json.loads(sys.argv[1]); print(v["matched_byte_start"],v["matched_byte_end"])' \
    "${target_result}")" || return 1
  read -r source_start source_end <<<"${source_range}"
  read -r target_start target_end <<<"${target_range}"
  host_sudo "${source_host}" /usr/bin/dd if="${host_agent_audit_log}" bs=1 \
    skip="${source_start}" count="$((source_end - source_start))" status=none \
    >"${leg_dir}/source-agent-detach.jsonl" || return 1
  host_sudo "${target_host}" /usr/bin/dd if="${host_agent_audit_log}" bs=1 \
    skip="${target_start}" count="$((target_end - target_start))" status=none \
    >"${leg_dir}/target-agent-attach.jsonl" || return 1

  host_sudo "${source_host}" /usr/bin/cat "${host_agent_state_file}" \
    >"${leg_dir}/source-agent-state-after.json" || return 1
  host_sudo "${target_host}" /usr/bin/cat "${host_agent_state_file}" \
    >"${leg_dir}/target-agent-state-after.json" || return 1
  if host_sudo_probe "${source_host}" /usr/bin/test -e "${pin_root}"; then
    echo "source host retained the backend pin tree after migration" >&2
    return 1
  fi
  host_sudo "${target_host}" /usr/sbin/bpftool -j map show pinned "${pin_path}" \
    >"${leg_dir}/target-runtime-map-after.json" || return 1

  "${python_bin}" - \
    "${leg_dir}/source-agent-state-after.json" \
    "${leg_dir}/target-agent-state-after.json" \
    "${leg_dir}/target-runtime-map-after.json" \
    "${source_result}" "${target_result}" \
    "${phase}" "${source_host}" "${target_host}" \
    "${backend_server_id}" "${backend_port_id}" "${pin_path}" <<'PY'
import json
import sys
from pathlib import Path


def load(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, (dict, list)):
        raise SystemExit(f"invalid attachment evidence: {path}")
    return value


source_state = load(sys.argv[1])
target_state = load(sys.argv[2])
target_map = load(sys.argv[3])
source_event = json.loads(sys.argv[4])
target_event = json.loads(sys.argv[5])
phase, source_host, target_host, server_id, port_id, pin_path = sys.argv[6:12]
source_attachments = source_state.get("attachments")
target_attachments = target_state.get("attachments")
if not isinstance(source_attachments, dict) or port_id in source_attachments:
    raise SystemExit("source Agent still owns the backend after migration")
if not isinstance(target_attachments, dict) or port_id not in target_attachments:
    raise SystemExit("target Agent did not attach the backend after migration")
record = target_attachments[port_id]
binding = record.get("binding") if isinstance(record, dict) else None
if not isinstance(binding, dict) or {
    "server_id": binding.get("server_id"),
    "port_id": binding.get("port_id"),
    "host": str(binding.get("host", "")).split(".", 1)[0],
} != {"server_id": server_id, "port_id": port_id, "host": target_host}:
    raise SystemExit("target Agent binding does not match migrated placement")
if (
    not isinstance(binding.get("ifindex"), int)
    or binding["ifindex"] <= 0
    or record.get("healthy") is not True
    or record.get("missing_pins") != []
    or record.get("hook_ownership_verified") is not True
    or record.get("program_ids") != record.get("current_program_ids")
):
    raise SystemExit("target Agent attachment is not healthy")
map_value = target_map[0] if isinstance(target_map, list) and len(target_map) == 1 else target_map
if not isinstance(map_value, dict) or not isinstance(map_value.get("id"), int):
    raise SystemExit("target runtime map identity is invalid")
result = {
    "ready": True,
    "phase": phase,
    "source_host": source_host,
    "target_host": target_host,
    "source_detached": True,
    "target_attached": True,
    "source_event": source_event,
    "target_event": target_event,
    "target_runtime_map": {"host": target_host, "path": pin_path, "id": map_value["id"]},
    "target_binding": binding,
}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
}

continuity_unit_name() {
  printf 'vnet-dataplane-migration-continuity-%s-%s.service\n' \
    "${continuity_run_id}" "$1"
}

continuity_phase_dir() {
  printf '%s/%s/%s\n' "${continuity_remote_root}" \
    "${continuity_run_id}" "$1"
}

wait_continuity_unit_absent() {
  local unit="$1" raw="$2"
  local attempt active_state="" load_state="" rc=0
  : >"${raw}"
  for attempt in $(seq 1 200); do
    rc=0
    load_state="$(remote_sudo_probe "${client_guest_host}" \
      /usr/bin/systemctl show -p LoadState --value "${unit}" \
      2>>"${raw}")" || rc=$?
    printf 'attempt=%s load_state=%s rc=%s\n' \
      "${attempt}" "${load_state}" "${rc}" >>"${raw}"
    if [[ "${rc}" == 0 && "${load_state}" == not-found ]]; then
      return 0
    fi
    active_state="$(remote_sudo_probe "${client_guest_host}" \
      /usr/bin/systemctl show -p ActiveState --value "${unit}" \
      2>>"${raw}")" || true
    if [[ "${active_state}" != active && "${active_state}" != activating &&
          "${active_state}" != deactivating ]]; then
      remote_sudo_probe "${client_guest_host}" /usr/bin/systemctl \
        reset-failed "${unit}" >>"${raw}" 2>&1 || true
    fi
    sleep 0.1
  done
  return 1
}

remove_continuity_remote_tree() {
  local phase="$1"
  local run_root="${continuity_remote_root}/${continuity_run_id}"
  local phase_dir
  phase_dir="$(continuity_phase_dir "${phase}")"
  [[ "${phase_dir}" == "${run_root}/${phase}" ]] || return 1
  remote_sudo_probe "${client_guest_host}" /usr/bin/test ! -L \
    "${continuity_remote_root}" || return 1
  remote_sudo_probe "${client_guest_host}" /usr/bin/test ! -L \
    "${run_root}" || return 1
  if remote_sudo_probe "${client_guest_host}" /usr/bin/test -e \
       "${phase_dir}"; then
    remote_sudo_probe "${client_guest_host}" /usr/bin/test ! -L \
      "${phase_dir}" || return 1
    local resolved
    resolved="$(remote_sudo_probe "${client_guest_host}" \
      /usr/bin/readlink -f -- "${phase_dir}")" || return 1
    [[ "${resolved}" == "${phase_dir}" ]] || return 1
    remote_sudo "${client_guest_host}" /usr/bin/rm -rf -- \
      "${phase_dir}" || return 1
  fi
  if remote_sudo_probe "${client_guest_host}" /usr/bin/test -d \
       "${run_root}"; then
    remote_sudo "${client_guest_host}" /usr/bin/rmdir -- \
      "${run_root}" || return 1
  fi
  remote_sudo_probe "${client_guest_host}" /usr/bin/test ! -e \
    "${run_root}"
}

emit_continuity_result() {
  local operation="$1" phase="$2" passed="$3" cleanup_passed="$4"
  local evidence_complete="$5" probe_passed="$6" unit="$7"
  local remote_dir="$8" summary_path="$9"
  "${python_bin}" - "${operation}" "${phase}" "${passed}" \
    "${cleanup_passed}" "${evidence_complete}" "${probe_passed}" \
    "${unit}" "${remote_dir}" "${summary_path}" <<'PY'
import json
import sys
from pathlib import Path


def boolean(value):
    return value == "true"


summary_path = Path(sys.argv[9]) if sys.argv[9] else None
summary = None
if summary_path is not None and summary_path.is_file():
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
result = {
    "schema": 1,
    "operation": sys.argv[1],
    "phase": sys.argv[2],
    "passed": boolean(sys.argv[3]),
    "cleanup_passed": boolean(sys.argv[4]),
    "evidence_complete": boolean(sys.argv[5]),
    "probe_passed": boolean(sys.argv[6]),
    "unit": sys.argv[7],
    "remote_dir": sys.argv[8],
    "summary": summary,
}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
}

stop_continuity_probe() {
  local operation="$1" phase="$2"
  local evidence_dir="${out_dir}/migration/${phase}/continuity"
  local unit remote_dir load_state="" active_state="" probe_passed=false
  local unit_was_active=false
  local cleanup_passed=true evidence_complete=true wrapper_passed=false
  unit="$(continuity_unit_name "${phase}")"
  remote_dir="$(continuity_phase_dir "${phase}")"
  mkdir -p "${evidence_dir}"

  load_state="$(remote_sudo_probe "${client_guest_host}" \
    /usr/bin/systemctl show -p LoadState --value "${unit}" \
    2>"${evidence_dir}/unit-stop.err")" || true
  if [[ "${load_state}" != not-found ]]; then
    active_state="$(remote_sudo_probe "${client_guest_host}" \
      /usr/bin/systemctl show -p ActiveState --value "${unit}" \
      2>>"${evidence_dir}/unit-stop.err")" || true
    [[ "${active_state}" == active ]] && unit_was_active=true
    printf 'load_state=%s active_state=%s\n' \
      "${load_state}" "${active_state}" \
      >"${evidence_dir}/unit-before-stop.txt"
    remote_sudo "${client_guest_host}" /usr/bin/systemctl stop "${unit}" \
      >"${evidence_dir}/systemctl-stop.txt" 2>&1 || true
  else
    printf 'load_state=not-found active_state=unknown\n' \
      >"${evidence_dir}/unit-before-stop.txt"
    printf 'unit already absent: %s\n' "${unit}" \
      >"${evidence_dir}/systemctl-stop.txt"
  fi
  wait_continuity_unit_absent "${unit}" \
    "${evidence_dir}/unit-absence.txt" || cleanup_passed=false
  remote_sudo_probe "${client_guest_host}" /usr/bin/journalctl \
    --no-pager -n 200 -u "${unit}" \
    >"${evidence_dir}/journal.txt" 2>&1 || true

  local name
  for name in summary.json dns.jsonl grpc.jsonl; do
    if remote_sudo_probe "${client_guest_host}" /usr/bin/test -f \
         "${remote_dir}/${name}"; then
      remote_sudo "${client_guest_host}" /usr/bin/cat \
        "${remote_dir}/${name}" >"${evidence_dir}/${name}" || \
        evidence_complete=false
    else
      evidence_complete=false
    fi
  done
  if [[ -s "${evidence_dir}/summary.json" ]]; then
    if ! probe_passed="$("${python_bin}" - \
         "${evidence_dir}/summary.json" "${phase}" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if value.get("schema_version") != 1 or value.get("phase") != sys.argv[2]:
    raise SystemExit("continuity summary identity mismatch")
for protocol in ("dns", "grpc"):
    item = value.get(protocol)
    if not isinstance(item, dict) or not isinstance(item.get("samples"), int):
        raise SystemExit("continuity summary is incomplete")
print("true" if value.get("passed") is True else "false")
PY
    )"; then
      probe_passed=false
      evidence_complete=false
    fi
  else
    evidence_complete=false
  fi

  remove_continuity_remote_tree "${phase}" || cleanup_passed=false
  capture_process_absent_remote "${client_guest_host}" \
    '[m]igration_continuity_probe.py' \
    "${evidence_dir}/process-absence.txt" || cleanup_passed=false

  if [[ "${operation}" == abort ]]; then
    [[ "${cleanup_passed}" == true ]] && wrapper_passed=true
  elif [[ "${unit_was_active}" == true &&
          "${cleanup_passed}" == true &&
          "${evidence_complete}" == true &&
          "${probe_passed}" == true ]]; then
    wrapper_passed=true
  fi
  emit_continuity_result "${operation}" "${phase}" "${wrapper_passed}" \
    "${cleanup_passed}" "${evidence_complete}" "${probe_passed}" \
    "${unit}" "${remote_dir}" "${evidence_dir}/summary.json"
  [[ "${cleanup_passed}" == true ]]
}

start_continuity_probe() {
  local phase="$1"
  local evidence_dir="${out_dir}/migration/${phase}/continuity"
  local run_root="${continuity_remote_root}/${continuity_run_id}"
  local unit remote_dir active_state="" attempt first_samples_ready=0
  unit="$(continuity_unit_name "${phase}")"
  remote_dir="$(continuity_phase_dir "${phase}")"
  mkdir -p "${evidence_dir}"

  remote_sudo "${client_guest_host}" /usr/bin/install -d \
    -o root -g root -m 0700 "${continuity_remote_root}"
  remote_sudo_probe "${client_guest_host}" /usr/bin/test ! -L \
    "${continuity_remote_root}"
  remote_sudo_probe "${client_guest_host}" /usr/bin/test ! -L \
    "${run_root}"
  remote_sudo_probe "${client_guest_host}" /usr/bin/test ! -e \
    "${run_root}"
  remote_sudo "${client_guest_host}" /usr/bin/install -d \
    -o root -g root -m 0700 "${run_root}"

  if ! remote_sudo "${client_guest_host}" /usr/bin/systemd-run --quiet \
       --unit="${unit}" --collect \
       --property=Type=exec --property=KillMode=mixed \
       --property="TimeoutStopSec=${continuity_stop_timeout}s" \
       --property="RuntimeMaxSec=${continuity_max_duration}s" \
       /usr/bin/python3 \
       /opt/vnet-dataplane/linux_accel/bench/migration_continuity_probe.py \
       --phase "${phase}" --backend-ip "${backend_ip}" \
       --dns-harness \
       /opt/vnet-dataplane/linux_accel/build/openstack_dns_harness \
       --grpc-harness \
       /opt/vnet-dataplane/linux_accel/build/openstack_grpc_harness \
       --output-dir "${remote_dir}" --interval "${continuity_interval}" \
       --command-timeout "${continuity_command_timeout}" \
       --min-samples "${continuity_min_samples}" \
       >"${evidence_dir}/systemd-run.txt" 2>&1; then
    stop_continuity_probe abort "${phase}" \
      >"${evidence_dir}/start-rollback.json" 2>&1 || true
    return 1
  fi

  for attempt in $(seq 1 200); do
    active_state="$(remote_sudo_probe "${client_guest_host}" \
      /usr/bin/systemctl is-active "${unit}" 2>/dev/null)" || true
    if [[ "${active_state}" == active ]] &&
       remote_sudo_probe "${client_guest_host}" /usr/bin/test -s \
         "${remote_dir}/dns.jsonl" &&
       remote_sudo_probe "${client_guest_host}" /usr/bin/test -s \
         "${remote_dir}/grpc.jsonl"; then
      remote_sudo_probe "${client_guest_host}" /usr/bin/head -n 1 \
        "${remote_dir}/dns.jsonl" >"${evidence_dir}/start-dns.json"
      remote_sudo_probe "${client_guest_host}" /usr/bin/head -n 1 \
        "${remote_dir}/grpc.jsonl" >"${evidence_dir}/start-grpc.json"
      if "${python_bin}" - "${evidence_dir}/start-dns.json" \
           "${evidence_dir}/start-grpc.json" <<'PY'
import json
import sys
from pathlib import Path

for path in sys.argv[1:]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if value.get("success") is not True:
        raise SystemExit("continuity start sample failed")
PY
      then
        first_samples_ready=1
      fi
      break
    fi
    sleep 0.1
  done
  if [[ "${active_state}" != active || "${first_samples_ready}" != 1 ]]; then
    remote_sudo_probe "${client_guest_host}" /usr/bin/journalctl \
      --no-pager -n 200 -u "${unit}" \
      >"${evidence_dir}/start-failure-journal.txt" 2>&1 || true
    stop_continuity_probe abort "${phase}" \
      >"${evidence_dir}/start-rollback.json" 2>&1 || true
    return 1
  fi
  remote_sudo_probe "${client_guest_host}" /usr/bin/systemctl show \
    -p LoadState -p ActiveState -p SubState -p MainPID "${unit}" \
    >"${evidence_dir}/unit-start.txt"
  continuity_unit="${unit}"
  continuity_remote_dir="${remote_dir}"
  emit_continuity_result start "${phase}" true true false false \
    "${unit}" "${remote_dir}" ""
}

manage_continuity_probe() {
  local operation="$1" phase="$2"
  [[ "${phase}" == forward || "${phase}" == reverse ]] || {
    echo "unsupported continuity phase: ${phase}" >&2
    return 2
  }
  case "${operation}" in
    start)
      start_continuity_probe "${phase}"
      ;;
    stop|abort)
      stop_continuity_probe "${operation}" "${phase}"
      ;;
    *)
      echo "unsupported continuity operation: ${operation}" >&2
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
  state="$(remote_sudo_probe "$(remote_service_target "${host}")" /usr/bin/systemctl show \
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
  local host="$1"
  local tap="$2"
  local ingress="${out_dir}/systemd/${tap}.tc-ingress.txt"
  local egress="${out_dir}/systemd/${tap}.tc-egress.txt"
  local status=0
  host_sudo "${host}" /usr/sbin/tc filter show dev "${tap}" ingress >"${ingress}" || status=1
  host_sudo "${host}" /usr/sbin/tc filter show dev "${tap}" egress >"${egress}" || status=1
  if grep -Eq 'handle 0x1 |handle 0x2 ' "${ingress}" "${egress}"; then
    echo "run-owned TC hook remains on ${tap}" >&2
    status=1
  fi
  if [[ "${require_netmig_tc}" == 1 ]]; then
    local ingress_identity="${out_dir}/systemd/${tap}.netmig-ingress-after.json"
    local egress_identity="${out_dir}/systemd/${tap}.netmig-egress-after.json"
    capture_tc_identity "${host}" "${tap}" ingress 0x65 "${ingress_identity}" || status=1
    capture_tc_identity "${host}" "${tap}" egress 0x66 "${egress_identity}" || status=1
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
  remote_sudo_probe "$(remote_service_target "${host}")" /usr/bin/systemctl show \
    -p LoadState -p ActiveState -p SubState -p Result "${unit}" \
    >"${raw}" 2>&1 || return 1
  grep -q '^LoadState=loaded$' "${raw}" &&
    grep -q '^ActiveState=inactive$' "${raw}" &&
    grep -q '^SubState=dead$' "${raw}" &&
    grep -q '^Result=success$' "${raw}"
}

capture_unit_inactive_compute() {
  local host="$1"
  local unit="$2"
  local raw="$3"
  if [[ "${source_compute_remote}" == 0 &&
        "${host}" == "${expected_compute_host}" ]]; then
    capture_unit_inactive_local "${unit}" "${raw}"
  else
    capture_unit_inactive_remote "${host}" "${unit}" "${raw}"
  fi
}

capture_unit_absent_remote() {
  local host="$1"
  local unit="$2"
  local raw="$3"
  remote_sudo_probe "$(remote_service_target "${host}")" /usr/bin/systemctl show \
    -p LoadState -p ActiveState -p SubState -p Result "${unit}" \
    >"${raw}" 2>&1 || return 1
  grep -q '^LoadState=not-found$' "${raw}"
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
  if remote_sudo_probe "$(remote_service_target "${host}")" /usr/bin/test ! -e "${path}"; then
    printf 'absent\t%s\t%s\n' "${host}" "${path}" >"${raw}"
    return 0
  else
    rc=$?
  fi
  printf 'not-absent-or-probe-error=%s\t%s\t%s\n' \
    "${rc}" "${host}" "${path}" >"${raw}"
  return "${rc}"
}

capture_path_absent_compute() {
  local host="$1"
  local path="$2"
  local raw="$3"
  if [[ "${source_compute_remote}" == 0 &&
        "${host}" == "${expected_compute_host}" ]]; then
    capture_path_absent_local "${path}" "${raw}"
  else
    capture_path_absent_remote "${host}" "${path}" "${raw}"
  fi
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
  remote_sudo_probe "$(remote_service_target "${host}")" /usr/bin/pgrep -af "${pattern}" \
    >"${raw}" 2>&1 || rc=$?
  if (( rc == 1 )); then
    printf '%s\n' 'no matching process' >>"${raw}"
    return 0
  fi
  (( rc == 0 )) && return 1
  return "${rc}"
}

capture_process_absent_compute() {
  local host="$1"
  local pattern="$2"
  local raw="$3"
  if [[ "${source_compute_remote}" == 0 &&
        "${host}" == "${expected_compute_host}" ]]; then
    capture_process_absent_local "${pattern}" "${raw}"
  else
    capture_process_absent_remote "${host}" "${pattern}" "${raw}"
  fi
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
    "continuity_absent",
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
    "continuity_absent",
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
        "source-compute-agent.systemctl.txt",
        "target-compute-agent.systemctl.txt",
        "client-guest-agent.systemctl.txt",
        "backend-guest-agent.systemctl.txt",
        "backend-dns.systemctl.txt",
        "backend-grpc.systemctl.txt",
        "source-compute-client-pin.txt",
        "source-compute-backend-pin.txt",
        "target-compute-client-pin.txt",
        "target-compute-backend-pin.txt",
        "client-guest-pin.txt",
        "backend-guest-pin.txt",
        "source-compute-client-quiesce.txt",
        "source-compute-backend-quiesce.txt",
        "target-compute-client-quiesce.txt",
        "target-compute-backend-quiesce.txt",
        "client-guest-quiesce.txt",
        "backend-guest-quiesce.txt",
        "source-compute-agent.pgrep.txt",
        "master-coordinator.pgrep.txt",
        "master-metrics.pgrep.txt",
        "target-compute-agent.pgrep.txt",
        "client-guest-agent.pgrep.txt",
        "backend-guest-agent.pgrep.txt",
        "client-grpc-cache.pgrep.txt",
        "backend-grpc-cache.pgrep.txt",
        "backend-dns-monitor.pgrep.txt",
        "client-dns-harness.pgrep.txt",
        "backend-dns-harness.pgrep.txt",
        "client-grpc-harness.pgrep.txt",
        "backend-grpc-harness.pgrep.txt",
        "source-compute-client-interface.ip-link.txt",
        "source-compute-backend-interface.ip-link.txt",
        "backend-guest-ens3.ip-link.txt",
        "backend-guest.ss-udp.txt",
        "backend-guest.ss-tcp.txt",
        "client-guest.ss-tcp.txt",
        "client-continuity-forward.systemctl.txt",
        "client-continuity-reverse.systemctl.txt",
        "client-continuity-run-dir.txt",
        "client-continuity-probe.pgrep.txt",
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
  local tc_cleanup=true continuity_absent=true
  mkdir -p "${raw_dir}"

  capture_unit_inactive_local "${coordinator_unit}" "${raw_dir}/master-coordinator.systemctl.txt" || units_inactive=false
  capture_unit_inactive_local "${metrics_unit}" "${raw_dir}/master-metrics.systemctl.txt" || units_inactive=false
  capture_unit_inactive_compute "${expected_compute_host}" "${host_agent_unit}" "${raw_dir}/source-compute-agent.systemctl.txt" || units_inactive=false
  capture_unit_inactive_compute "${compute2_host}" "${host_agent_unit}" "${raw_dir}/target-compute-agent.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${client_guest_host}" "${guest_agent_unit}" "${raw_dir}/client-guest-agent.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${backend_guest_host}" "${guest_agent_unit}" "${raw_dir}/backend-guest-agent.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${backend_guest_host}" "${dns_backend_unit}" "${raw_dir}/backend-dns.systemctl.txt" || units_inactive=false
  capture_unit_inactive_remote "${backend_guest_host}" "${grpc_backend_unit}" "${raw_dir}/backend-grpc.systemctl.txt" || units_inactive=false
  [[ "${units_inactive}" == true ]] || status=1

  capture_path_absent_compute "${expected_compute_host}" "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}" "${raw_dir}/source-compute-client-pin.txt" || pins_removed=false
  capture_path_absent_compute "${expected_compute_host}" "/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}" "${raw_dir}/source-compute-backend-pin.txt" || pins_removed=false
  capture_path_absent_compute "${compute2_host}" "/sys/fs/bpf/vnet-dataplane-agent/${client_port_id}" "${raw_dir}/target-compute-client-pin.txt" || pins_removed=false
  capture_path_absent_compute "${compute2_host}" "/sys/fs/bpf/vnet-dataplane-agent/${backend_port_id}" "${raw_dir}/target-compute-backend-pin.txt" || pins_removed=false
  capture_path_absent_remote "${client_guest_host}" "/sys/fs/bpf/vnet-dataplane-guest/${client_port_id}" "${raw_dir}/client-guest-pin.txt" || pins_removed=false
  capture_path_absent_remote "${backend_guest_host}" "/sys/fs/bpf/vnet-dataplane-guest/${backend_port_id}" "${raw_dir}/backend-guest-pin.txt" || pins_removed=false
  [[ "${pins_removed}" == true ]] || status=1

  capture_path_absent_compute "${expected_compute_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${client_port_id}.quiesce" "${raw_dir}/source-compute-client-quiesce.txt" || quiesce_removed=false
  capture_path_absent_compute "${expected_compute_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${backend_port_id}.quiesce" "${raw_dir}/source-compute-backend-quiesce.txt" || quiesce_removed=false
  capture_path_absent_compute "${compute2_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${client_port_id}.quiesce" "${raw_dir}/target-compute-client-quiesce.txt" || quiesce_removed=false
  capture_path_absent_compute "${compute2_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${backend_port_id}.quiesce" "${raw_dir}/target-compute-backend-quiesce.txt" || quiesce_removed=false
  capture_path_absent_remote "${client_guest_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${client_port_id}.quiesce" "${raw_dir}/client-guest-quiesce.txt" || quiesce_removed=false
  capture_path_absent_remote "${backend_guest_host}" "/run/vnet-dataplane-policy/vnet-dataplane-${backend_port_id}.quiesce" "${raw_dir}/backend-guest-quiesce.txt" || quiesce_removed=false
  [[ "${quiesce_removed}" == true ]] || status=1

  capture_process_absent_compute "${expected_compute_host}" '[o]penstack_dataplane_agent.py' "${raw_dir}/source-compute-agent.pgrep.txt" || processes_absent=false
  capture_process_absent_local '[o]penstack_epoch_coordinator.py' "${raw_dir}/master-coordinator.pgrep.txt" || processes_absent=false
  capture_process_absent_local '[o]penstack_metrics_bridge.py' "${raw_dir}/master-metrics.pgrep.txt" || processes_absent=false
  capture_process_absent_compute "${compute2_host}" '[o]penstack_dataplane_agent.py' "${raw_dir}/target-compute-agent.pgrep.txt" || processes_absent=false
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

  if ! host_sudo "${expected_compute_host}" /usr/sbin/ip -details link show dev "${client_tap}" >"${raw_dir}/source-compute-client-interface.ip-link.txt" 2>&1; then
    xdp_detached=false
  elif grep -q 'prog/xdp' "${raw_dir}/source-compute-client-interface.ip-link.txt"; then
    echo "client host XDP hook remains after cleanup" >&2
    xdp_detached=false
  fi
  if ! host_sudo "${expected_compute_host}" /usr/sbin/ip -details link show dev "${backend_tap}" >"${raw_dir}/source-compute-backend-interface.ip-link.txt" 2>&1; then
    xdp_detached=false
  elif grep -q 'prog/xdp' "${raw_dir}/source-compute-backend-interface.ip-link.txt"; then
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

  capture_unit_absent_remote "${client_guest_host}" \
    "$(continuity_unit_name forward)" \
    "${raw_dir}/client-continuity-forward.systemctl.txt" || \
    continuity_absent=false
  capture_unit_absent_remote "${client_guest_host}" \
    "$(continuity_unit_name reverse)" \
    "${raw_dir}/client-continuity-reverse.systemctl.txt" || \
    continuity_absent=false
  capture_path_absent_remote "${client_guest_host}" \
    "${continuity_remote_root}/${continuity_run_id}" \
    "${raw_dir}/client-continuity-run-dir.txt" || continuity_absent=false
  capture_process_absent_remote "${client_guest_host}" \
    '[m]igration_continuity_probe.py' \
    "${raw_dir}/client-continuity-probe.pgrep.txt" || continuity_absent=false
  [[ "${continuity_absent}" == true ]] || status=1

  audit_tc_cleanup "${expected_compute_host}" "${client_tap}" || tc_cleanup=false
  audit_tc_cleanup "${expected_compute_host}" "${backend_tap}" || tc_cleanup=false
  [[ "${tc_cleanup}" == true ]] || status=1

  {
    printf 'units_inactive\t%s\n' "${units_inactive}"
    printf 'pins_removed\t%s\n' "${pins_removed}"
    printf 'quiesce_removed\t%s\n' "${quiesce_removed}"
    printf 'processes_absent\t%s\n' "${processes_absent}"
    printf 'xdp_detached\t%s\n' "${xdp_detached}"
    printf 'listeners_absent\t%s\n' "${listeners_absent}"
    printf 'tc_cleanup\t%s\n' "${tc_cleanup}"
    printf 'continuity_absent\t%s\n' "${continuity_absent}"
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
        systemctl_remote "$(remote_service_target "${node}")" \
          "${operation}" "${unit}"
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
    migration-baseline)
      capture_migration_baseline "$@"
      ;;
    wait-transition)
      wait_migration_transition "$@"
      ;;
    wait-attachment)
      wait_migration_attachment "$@"
      ;;
    continuity)
      manage_continuity_probe "$@"
      ;;
    migration)
      run_migration_leg "$@"
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
  if [[ "${source_compute_remote}" == 1 ]]; then
    action service remote "${expected_compute_host}" stop "${host_agent_unit}" || status=1
  else
    action service local master stop "${host_agent_unit}" || status=1
  fi
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
  if [[ "${source_compute_remote}" == 1 ]]; then
    action service remote "${expected_compute_host}" start "${host_agent_unit}"
  else
    action service local master start "${host_agent_unit}"
  fi
  action audit-running
  action service local master start "${metrics_unit}"
  if [[ "${execution_mode}" == real ]]; then
    metrics_invocation_id="$(local_sudo /usr/bin/systemctl show \
      --property InvocationID --value "${metrics_unit}")"
    [[ "${metrics_invocation_id}" =~ ^[0-9a-f]{32}$ ]] || {
      echo "metrics service returned an invalid InvocationID" >&2
      return 1
    }
  fi
  coordinator_started=1
  action service local master start "${coordinator_unit}"
}

capture_metrics_journal() {
  [[ "${execution_mode}" == real ]] || return 0
  [[ "${metrics_invocation_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  mkdir -p "${out_dir}/systemd"
  local_sudo /usr/bin/journalctl --no-pager -o short-iso \
    "_SYSTEMD_INVOCATION_ID=${metrics_invocation_id}" \
    >"${out_dir}/systemd/master-metrics.journal.txt"
  test -s "${out_dir}/systemd/master-metrics.journal.txt"
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
  printf '{"status":"%s","execution_mode":"%s","preflight_only":%s,"cleanup_audit_only":%s,"experiment_executed":%s,"formal_rounds":0,"baseline_epoch":%s,"bypass_epoch":%s,"server_epoch":%s,"dns_backend_suppressed":%s,"dns_acceleration":"guest_xdp_server_cache","grpc_acceleration":"guest_userspace_h2c_fast_cache","grpc_kernel_response":false,"host_tc_role":"observation_and_coexistence","migration_mode":"%s","migration_roundtrip_completed":%s,"cleanup_status":%s}\n' \
    "${status}" "${execution_mode}" "${preflight_only}" "${cleanup_audit_only}" "${experiment_executed}" \
    "${baseline_epoch}" "${bypass_epoch}" "${server_epoch}" \
    "${dns_backend_suppressed}" "${migration_mode}" \
    "${migration_roundtrip_completed}" "${cleanup_status}" \
    >"${out_dir}/result-summary.json"
}

write_roundtrip_artifact() {
  mkdir -p "${out_dir}/migration"
  printf '{"schema":1,"completed":%s,"final_host":"%s","recovery_attempted":%s,"recovery_completed":%s}\n' \
    "${migration_roundtrip_completed}" "${backend_current_host}" \
    "${migration_recovery_attempted}" "${migration_recovery_completed}" \
    >"${out_dir}/migration/roundtrip.json"
}

validate_migration_artifact() {
  local path="$1" expected_phase="$2" expected_source="$3"
  local expected_target="$4" evidence_dir="$5"
  "${python_bin}" - "${path}" "${expected_phase}" "${expected_source}" \
    "${expected_target}" "${backend_server_id}" "${backend_port_id}" \
    "${evidence_dir}" "${execution_mode}" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
phase, expected_source, expected_target = sys.argv[2:5]
server_id, port_id = sys.argv[5:7]
evidence_dir = Path(sys.argv[7])
execution_mode = sys.argv[8]
if not isinstance(value, dict) or value.get("schema") != 1:
    raise SystemExit("migration artifact has unsupported schema")
if value.get("phase") != phase or value.get("status") != "completed":
    raise SystemExit("migration artifact does not prove completion")
expected = {
    "server_id": server_id,
    "port_id": port_id,
    "target_host": expected_target,
    "final_host": expected_target,
    "requested_source_host": expected_source,
}
if any(value.get(key) != item for key, item in expected.items()):
    raise SystemExit("migration artifact identity does not match the requested leg")
if phase != "restore" and value.get("source_host") != expected_source:
    raise SystemExit("migration artifact has an unexpected source host")
if not isinstance(value.get("source_host"), str) or not value["source_host"]:
    raise SystemExit("migration artifact has no effective source host")
outcome = value.get("outcome")
migration_id = value.get("migration_id")
if phase != "restore" or outcome == "completed":
    if not isinstance(migration_id, str) or not migration_id:
        raise SystemExit("migration artifact has no migration ID")
elif outcome == "already_on_target":
    if migration_id is not None:
        raise SystemExit("idempotent restore unexpectedly has a migration ID")
else:
    raise SystemExit("restore artifact has an unsupported outcome")

if execution_mode == "real":
    raw_summary = json.loads(
        (evidence_dir / "summary.json").read_text(encoding="utf-8")
    )
    if raw_summary != value:
        raise SystemExit("migration stdout and raw summary differ")
    events = [
        json.loads(line)
        for line in (evidence_dir / "events.jsonl").read_text(
            encoding="utf-8"
        ).splitlines()
        if line.strip()
    ]
    event_name = (
        "migration_already_on_target"
        if outcome == "already_on_target"
        else "migration_completed"
    )
    completions = [item for item in events if item.get("event") == event_name]
    if not completions:
        raise SystemExit("migration events have no matching completion record")
    completion = completions[-1]
    for key in (
        "phase",
        "server_id",
        "port_id",
        "source_host",
        "target_host",
        "final_host",
        "migration_id",
    ):
        if completion.get(key) != value.get(key):
            raise SystemExit(f"migration completion event differs at {key}")
PY
}

validate_migration_baseline() {
  local path="$1" expected_phase="$2" source_host="$3"
  local target_host="$4" after_epoch="$5"
  "${python_bin}" - "${path}" "${expected_phase}" "${source_host}" \
    "${target_host}" "${after_epoch}" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schema": 1,
    "phase": sys.argv[2],
    "source_host": sys.argv[3],
    "target_host": sys.argv[4],
    "after_epoch": int(sys.argv[5]),
}
if not isinstance(value, dict) or any(value.get(key) != item for key, item in expected.items()):
    raise SystemExit("migration baseline does not match the requested leg")
for name in ("coordinator", "source_agent", "target_agent"):
    cursor = value.get(name)
    if not isinstance(cursor, dict):
        raise SystemExit(f"migration baseline cursor is missing: {name}")
    for field in ("device", "inode", "offset"):
        item = cursor.get(field)
        if isinstance(item, bool) or not isinstance(item, int) or item < 0:
            raise SystemExit(f"migration baseline cursor is invalid: {name}/{field}")
PY
}

validate_transition_artifact() {
  local path="$1" after_epoch="$2"
  "${python_bin}" - "${path}" "${after_epoch}" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
epoch = value.get("epoch") if isinstance(value, dict) else None
if value.get("ready") is not True:
    raise SystemExit("migration transition is not ready")
if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch <= int(sys.argv[2]):
    raise SystemExit("migration transition epoch is not fresh")
if value.get("outcome") not in {
    "migration_forced_bypass",
    "migration_frozen_in_bypass",
    "gate_changed_bypass_recovered",
}:
    raise SystemExit("migration transition outcome is invalid")
PY
}

validate_attachment_artifact() {
  local path="$1" expected_phase="$2" source_host="$3" target_host="$4"
  "${python_bin}" - "${path}" "${expected_phase}" "${source_host}" \
    "${target_host}" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "ready": True,
    "phase": sys.argv[2],
    "source_host": sys.argv[3],
    "target_host": sys.argv[4],
    "source_detached": True,
    "target_attached": True,
}
if not isinstance(value, dict) or any(value.get(key) != item for key, item in expected.items()):
    raise SystemExit("migration attachment proof is incomplete")
PY
}

validate_continuity_artifact() {
  local path="$1" operation="$2" phase="$3"
  "${python_bin}" - "${path}" "${operation}" "${phase}" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(value, dict) or value.get("schema") != 1:
    raise SystemExit("continuity artifact has unsupported schema")
if value.get("operation") != sys.argv[2] or value.get("phase") != sys.argv[3]:
    raise SystemExit("continuity artifact does not match the requested action")
if value.get("passed") is not True:
    raise SystemExit("continuity probe did not pass")
PY
}

run_migration_sequence() {
  local phase="$1" source_host="$2" target_host="$3"
  local fence_epoch="${server_epoch}"
  local leg_dir="${out_dir}/migration/${phase}"
  mkdir -p "${leg_dir}"

  action migration-baseline "${phase}" "${source_host}" "${target_host}" \
    "${fence_epoch}" >"${leg_dir}/baseline.json"
  validate_migration_baseline "${leg_dir}/baseline.json" "${phase}" \
    "${source_host}" "${target_host}" "${fence_epoch}"

  continuity_active=1
  continuity_phase="${phase}"
  action continuity start "${phase}" >"${leg_dir}/continuity-start.json"
  validate_continuity_artifact "${leg_dir}/continuity-start.json" start "${phase}"

  if ! action migration "${phase}" "${backend_server_id}" \
       "${source_host}" "${target_host}" \
       >"${out_dir}/migration/${phase}.json" \
       2>"${out_dir}/migration/${phase}.err"; then
    printf '%s migration action failed\n' "${phase}" \
      >>"${out_dir}/migration/${phase}.err"
    return 1
  fi
  backend_current_host="${target_host}"
  validate_migration_artifact "${out_dir}/migration/${phase}.json" \
    "${phase}" "${source_host}" "${target_host}" \
    "${out_dir}/migration/${phase}/openstack" || return 1
  write_roundtrip_artifact

  action wait-transition "${phase}" "${source_host}" "${target_host}" \
    "${fence_epoch}" >"${leg_dir}/transition.json"
  validate_transition_artifact "${leg_dir}/transition.json" "${fence_epoch}"
  local transition_epoch
  transition_epoch="$(json_epoch "${leg_dir}/transition.json")"

  action wait-attachment "${phase}" "${source_host}" "${target_host}" \
    >"${leg_dir}/attachment.json"
  validate_attachment_artifact "${leg_dir}/attachment.json" "${phase}" \
    "${source_host}" "${target_host}"

  action wait-committed server "${transition_epoch}" \
    >"${leg_dir}/committed-server.json"
  server_epoch="$(json_epoch "${leg_dir}/committed-server.json")"

  action continuity stop "${phase}" >"${leg_dir}/continuity-stop.json"
  continuity_active=0
  continuity_phase=""
  validate_continuity_artifact "${leg_dir}/continuity-stop.json" stop "${phase}"
}

run_roundtrip_migration() {
  mkdir -p "${out_dir}/migration"
  migration_started=1
  write_roundtrip_artifact
  run_migration_sequence forward "${expected_compute_host}" "${compute2_host}"
  run_migration_sequence reverse "${compute2_host}" "${expected_compute_host}"
  migration_roundtrip_completed=true
  write_roundtrip_artifact
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
    if (( continuity_active != 0 )); then
      if action continuity abort "${continuity_phase}" \
           >"${out_dir}/migration/${continuity_phase}/continuity-abort.json" \
           2>"${out_dir}/migration/${continuity_phase}/continuity-abort.err" &&
         validate_continuity_artifact \
           "${out_dir}/migration/${continuity_phase}/continuity-abort.json" \
           abort "${continuity_phase}"; then
        continuity_active=0
      else
        cleanup_status=1
      fi
    fi
    if [[ "${migration_mode}" == roundtrip &&
          "${migration_started}" == 1 &&
          "${migration_roundtrip_completed}" != true ]]; then
      migration_recovery_attempted=true
      if action migration restore "${backend_server_id}" \
           "${backend_current_host}" "${expected_compute_host}" \
           >"${out_dir}/migration/recovery.json" \
           2>"${out_dir}/migration/recovery.err" &&
         validate_migration_artifact "${out_dir}/migration/recovery.json" \
           restore "${backend_current_host}" "${expected_compute_host}" \
           "${out_dir}/migration/restore/openstack"; then
        backend_current_host="${expected_compute_host}"
        migration_recovery_completed=true
      else
        cleanup_status=1
      fi
      write_roundtrip_artifact
    fi
    capture_metrics_journal || cleanup_status=1
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
    if [[ "${source_compute_remote}" == 1 ]]; then
      action service remote "${expected_compute_host}" stop "${host_agent_unit}" || cleanup_status=1
    else
      action service local master stop "${host_agent_unit}" || cleanup_status=1
    fi
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

if [[ "${source_compute_remote}" == 1 && "${skip_shared_preflight}" == 0 ]]; then
  run_shared_cluster_preflight
fi
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

if [[ "${migration_mode}" == roundtrip ]]; then
  run_roundtrip_migration
fi

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
