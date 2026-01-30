#!/usr/bin/env bash
# Start firecracker-containerd daemon.
# This script initializes the devmapper thin pool and starts the containerd daemon
# with Firecracker support.
#
# Run this script inside the Lima VM: limactl shell fc-lab
# Usage: ./scripts/containerd/start-fc-containerd.sh
#
# Prerequisites:
#   - firecracker-containerd installed
#   - CNI plugins installed

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/firecracker-containerd/config.toml"
SNAPSHOTTER_DIR="/var/lib/firecracker-containerd/snapshotter/devmapper"
POOL_NAME="fc-dev-thinpool"

echo "=============================================="
echo "  Starting firecracker-containerd"
echo "=============================================="
echo ""

# Check prerequisites
if ! command -v firecracker-containerd &>/dev/null; then
  echo "ERROR: firecracker-containerd not found."
  echo "Please run install-fc-containerd.sh first."
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG_FILE"
  echo "Please run install-fc-containerd.sh first."
  exit 1
fi

# Setup devmapper thin pool if not exists
setup_devmapper() {
  if sudo dmsetup info "$POOL_NAME" &>/dev/null; then
    echo "==> Thin pool $POOL_NAME already exists."
    return 0
  fi

  echo "==> Setting up devmapper thin pool..."

  sudo mkdir -p "$SNAPSHOTTER_DIR"

  # Create sparse files if not exist
  if [[ ! -f "${SNAPSHOTTER_DIR}/data" ]]; then
    sudo touch "${SNAPSHOTTER_DIR}/data"
    sudo truncate -s 100G "${SNAPSHOTTER_DIR}/data"
  fi

  if [[ ! -f "${SNAPSHOTTER_DIR}/metadata" ]]; then
    sudo touch "${SNAPSHOTTER_DIR}/metadata"
    sudo truncate -s 2G "${SNAPSHOTTER_DIR}/metadata"
  fi

  # Setup loop devices
  DATADEV=$(sudo losetup --output NAME --noheadings --associated "${SNAPSHOTTER_DIR}/data" 2>/dev/null || true)
  if [[ -z "$DATADEV" ]]; then
    DATADEV=$(sudo losetup --find --show "${SNAPSHOTTER_DIR}/data")
  fi

  METADEV=$(sudo losetup --output NAME --noheadings --associated "${SNAPSHOTTER_DIR}/metadata" 2>/dev/null || true)
  if [[ -z "$METADEV" ]]; then
    METADEV=$(sudo losetup --find --show "${SNAPSHOTTER_DIR}/metadata")
  fi

  # Create thin pool
  SECTORSIZE=512
  DATASIZE=$(sudo blockdev --getsize64 -q "$DATADEV")
  LENGTH_SECTORS=$((DATASIZE / SECTORSIZE))
  DATA_BLOCK_SIZE=128
  LOW_WATER_MARK=32768
  THINP_TABLE="0 ${LENGTH_SECTORS} thin-pool ${METADEV} ${DATADEV} ${DATA_BLOCK_SIZE} ${LOW_WATER_MARK} 1 skip_block_zeroing"

  sudo dmsetup create "$POOL_NAME" --table "$THINP_TABLE" 2>/dev/null || \
    sudo dmsetup reload "$POOL_NAME" --table "$THINP_TABLE" 2>/dev/null || true

  echo "==> Thin pool created."
}

# Create required directories
create_directories() {
  echo "==> Creating required directories..."
  sudo mkdir -p /var/lib/firecracker-containerd/containerd
  sudo mkdir -p /var/lib/firecracker-containerd/shim-base
  sudo mkdir -p /run/firecracker-containerd
}

# Start the daemon
start_daemon() {
  echo "==> Starting firecracker-containerd daemon..."
  echo ""
  echo "Press Ctrl+C to stop the daemon."
  echo ""
  echo "In another terminal, run containers with:"
  echo "  ./scripts/containerd/run-container.sh"
  echo ""
  echo "Or manually:"
  echo "  sudo firecracker-ctr --address /run/firecracker-containerd/containerd.sock \\"
  echo "    images pull --snapshotter devmapper docker.io/library/alpine:latest"
  echo ""
  echo "  sudo firecracker-ctr --address /run/firecracker-containerd/containerd.sock \\"
  echo "    run --snapshotter devmapper --runtime aws.firecracker --rm --tty \\"
  echo "    docker.io/library/alpine:latest test sh"
  echo ""
  echo "----------------------------------------------"
  echo ""

  sudo PATH="$PATH" firecracker-containerd --config "$CONFIG_FILE"
}

# Main
main() {
  setup_devmapper
  create_directories
  start_daemon
}

main
