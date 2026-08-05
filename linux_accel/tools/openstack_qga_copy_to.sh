#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <libvirt-instance-name> <host-source> <guest-destination> <mode>" >&2
    exit 2
fi

instance_name=$1
source_path=$2
destination_path=$3
destination_mode=$4
test -f "${source_path}"
[[ ${destination_mode} =~ ^0?[0-7]{3,4}$ ]]

open_request=$(jq -cn --arg path "${destination_path}" '{
    execute: "guest-file-open",
    arguments: {path: $path, mode: "w"}
}')
open_response=$(sudo virsh qemu-agent-command "${instance_name}" "${open_request}")
handle=$(jq -er '.return' <<<"${open_response}")

close_file() {
    set +e
    close_request=$(jq -cn --argjson handle "${handle}" '{
        execute: "guest-file-close", arguments: {handle: $handle}
    }')
    sudo virsh qemu-agent-command "${instance_name}" "${close_request}" >/dev/null 2>&1
}
trap close_file EXIT

expected=$(stat -c %s "${source_path}")
chunk_size=65536
chunk_index=0
written=0
while [ "${written}" -lt "${expected}" ]; do
    remaining=$((expected - written))
    chunk_expected=${chunk_size}
    if [ "${remaining}" -lt "${chunk_size}" ]; then
        chunk_expected=${remaining}
    fi
    file_data=$(dd if="${source_path}" bs="${chunk_size}" skip="${chunk_index}" count=1 status=none | base64 -w 0)
    write_request=$(jq -cn --argjson handle "${handle}" --arg data "${file_data}" '{
        execute: "guest-file-write",
        arguments: {handle: $handle, "buf-b64": $data}
    }')
    write_response=$(sudo virsh qemu-agent-command "${instance_name}" "${write_request}")
    chunk_written=$(jq -er '.return.count' <<<"${write_response}")
    test "${chunk_written}" -eq "${chunk_expected}"
    written=$((written + chunk_written))
    chunk_index=$((chunk_index + 1))
done
test "${written}" -eq "${expected}"

flush_request=$(jq -cn --argjson handle "${handle}" '{
    execute: "guest-file-flush", arguments: {handle: $handle}
}')
sudo virsh qemu-agent-command "${instance_name}" "${flush_request}" >/dev/null
close_file
trap - EXIT

chmod_command=$(jq -cn --arg command "chmod ${destination_mode} ${destination_path}" '{
    execute: "guest-exec",
    arguments: {path: "/bin/bash", arg: ["-lc", $command], "capture-output": true}
}')
chmod_response=$(sudo virsh qemu-agent-command "${instance_name}" "${chmod_command}")
chmod_pid=$(jq -er '.return.pid' <<<"${chmod_response}")
for _ in $(seq 1 100); do
    status_request=$(jq -cn --argjson pid "${chmod_pid}" '{
        execute: "guest-exec-status", arguments: {pid: $pid}
    }')
    status=$(sudo virsh qemu-agent-command "${instance_name}" "${status_request}")
    if [ "$(jq -r '.return.exited' <<<"${status}")" = "true" ]; then
        test "$(jq -r '.return.exitcode // 1' <<<"${status}")" -eq 0
        echo "qga_copy destination=${destination_path} bytes=${written} mode=${destination_mode}"
        exit 0
    fi
    sleep 0.1
done

echo "guest chmod timed out" >&2
exit 124
