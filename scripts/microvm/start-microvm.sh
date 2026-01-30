#!/usr/bin/env bash
# Start Firecracker MicroVM (kernel + rootfs from vm_config.json).
# Run inside Lima VM: limactl shell fc-lab
# Usage (from project root inside Lima): ./scripts/microvm/start-microvm.sh

set -euo pipefail

IMAGES_DIR="${MICROVM_IMAGES_DIR:-$HOME/microvm-images}"
CONFIG="${IMAGES_DIR}/vm_config.json"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: vm_config.json not found. Run setup-microvm-images.sh first."
  echo "  Expected: $CONFIG"
  exit 1
fi

cd "$IMAGES_DIR"
exec firecracker --no-api --config-file vm_config.json
