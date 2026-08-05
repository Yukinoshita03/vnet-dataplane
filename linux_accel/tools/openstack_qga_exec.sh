#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <libvirt-instance-name> <shell-command>" >&2
    exit 2
fi

instance_name=$1
shift
guest_command=$*

request=$(jq -cn --arg command "${guest_command}" '{
    execute: "guest-exec",
    arguments: {
        path: "/bin/bash",
        arg: ["-lc", $command],
        "capture-output": true
    }
}')
response=$(sudo virsh qemu-agent-command "${instance_name}" "${request}")
guest_pid=$(jq -er '.return.pid' <<<"${response}")

for _ in $(seq 1 600); do
    status_request=$(jq -cn --argjson pid "${guest_pid}" '{
        execute: "guest-exec-status",
        arguments: {pid: $pid}
    }')
    status=$(sudo virsh qemu-agent-command "${instance_name}" "${status_request}")
    if [ "$(jq -r '.return.exited' <<<"${status}")" = "true" ]; then
        stdout_data=$(jq -r '.return["out-data"] // empty' <<<"${status}")
        stderr_data=$(jq -r '.return["err-data"] // empty' <<<"${status}")
        exit_code=$(jq -r '.return.exitcode // 1' <<<"${status}")
        if [ -n "${stdout_data}" ]; then
            printf '%s' "${stdout_data}" | base64 -d
        fi
        if [ -n "${stderr_data}" ]; then
            printf '%s' "${stderr_data}" | base64 -d >&2
        fi
        exit "${exit_code}"
    fi
    sleep 0.1
done

echo "guest command timed out: pid=${guest_pid}" >&2
exit 124
