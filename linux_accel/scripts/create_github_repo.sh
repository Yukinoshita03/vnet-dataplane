#!/usr/bin/env bash
set -euo pipefail

repo_name="${1:-ebpf-network-service-cache}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is not installed"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not logged in. Run: gh auth login"
  exit 1
fi

gh repo create "$repo_name" --public --source=. --remote=origin --push
