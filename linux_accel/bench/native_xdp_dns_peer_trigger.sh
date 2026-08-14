#!/usr/bin/env bash
set -euo pipefail

peer_host="${PEER_HOST:?set PEER_HOST to the external peer IPv4 address}"
peer_port="${PEER_PORT:-45953}"

if [[ ! "${peer_host}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
   [[ ! "${peer_port}" =~ ^[1-9][0-9]*$ ]] ||
   (( peer_port > 65535 )); then
  echo "invalid PEER_HOST or PEER_PORT" >&2
  exit 2
fi

exec 3<>"/dev/tcp/${peer_host}/${peer_port}"
printf 'GO\n' >&3
cat <&3
