#!/usr/bin/env bash
set -euo pipefail

args_file=${MOCK_DNS_MONITOR_ARGS_FILE:?MOCK_DNS_MONITOR_ARGS_FILE is required}
printf '%s\n' "$@" >"${args_file}"

trap 'exit 0' INT TERM
while true; do
  sleep 0.1
done
