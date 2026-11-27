#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo "fix-permissions: root required" >&2; exit 1; }

echo "Disabled: recursive privileged ownership changes in steam-writable trees are unsafe. Repair offline from a trusted maintenance environment." >&2
exit 1
