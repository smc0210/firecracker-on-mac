#!/usr/bin/env bash
# From Mac host: start Lima fc-lab (if needed), then run Firecracker MicroVM inside it.
# Usage (from project root): ./scripts/microvm/start-from-host.sh
# (Or: bash scripts/microvm/start-from-host.sh. chmod +x scripts/microvm/*.sh once to drop bash.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
START_MICROVM="${SCRIPT_DIR}/start-microvm.sh"
LIMA_YAML="${PROJECT_ROOT}/firecracker-lab.yaml"
LIMA_INSTANCE="fc-lab"

# Start Lima VM if not running (blocks until READY)
if ! limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -q "^${LIMA_INSTANCE} Running"; then
  echo "==> Starting Lima instance \"${LIMA_INSTANCE}\"..."
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -q "^${LIMA_INSTANCE}$"; then
    limactl start "$LIMA_INSTANCE"
  else
    limactl start --name "$LIMA_INSTANCE" "$LIMA_YAML"
  fi
fi

# Run MicroVM start script inside Lima (this attaches to serial console)
exec limactl shell "$LIMA_INSTANCE" -- bash "$START_MICROVM"
