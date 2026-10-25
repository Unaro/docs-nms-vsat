#!/usr/bin/env bash
# Compatibility entry point. Cluster configuration has one implementation.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/configure-ha.sh" "$@"
