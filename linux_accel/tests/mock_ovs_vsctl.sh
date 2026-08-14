#!/usr/bin/env bash
set -euo pipefail

field=${*: -1}
case "${field}" in
  external_ids:iface-id)
    printf '"%s"\n' "${MOCK_OVS_IFACE_ID:-}"
    ;;
  external_ids:attached-mac)
    printf '"%s"\n' "${MOCK_OVS_ATTACHED_MAC:-}"
    ;;
  *)
    echo "unsupported mock ovs-vsctl field: ${field}" >&2
    exit 2
    ;;
esac
