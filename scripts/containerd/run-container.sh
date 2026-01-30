#!/usr/bin/env bash
# Run a container inside a Firecracker MicroVM using firecracker-containerd.
# This script demonstrates the complete workflow of pulling an image and running
# a container within an isolated MicroVM.
#
# Run this script inside the Lima VM: limactl shell fc-lab
# Usage: ./scripts/containerd/run-container.sh [image] [container-name] [command...]
#
# Examples:
#   ./scripts/containerd/run-container.sh                              # Run alpine with sh
#   ./scripts/containerd/run-container.sh alpine:latest test-alpine    # Run alpine as test-alpine
#   ./scripts/containerd/run-container.sh nginx:alpine my-nginx        # Run nginx
#
# Prerequisites:
#   - firecracker-containerd installed and configured
#   - CNI plugins installed
#   - firecracker-containerd daemon running

set -euo pipefail

# Configuration
FC_CTR="firecracker-ctr"
FC_SOCK="/run/firecracker-containerd/containerd.sock"
SNAPSHOTTER="devmapper"
RUNTIME="aws.firecracker"

# Default values
IMAGE="${1:-docker.io/library/alpine:latest}"
CONTAINER_NAME="${2:-fc-test-$(date +%s)}"
shift 2 2>/dev/null || true
COMMAND="${*:-sh}"

echo "=============================================="
echo "  Firecracker Container Runner"
echo "=============================================="
echo ""
echo "Image:     $IMAGE"
echo "Container: $CONTAINER_NAME"
echo "Command:   $COMMAND"
echo ""

# Check if firecracker-containerd is running
check_daemon() {
  if [[ ! -S "$FC_SOCK" ]]; then
    echo "ERROR: firecracker-containerd is not running."
    echo ""
    echo "Start it with:"
    echo "  sudo firecracker-containerd --config /etc/firecracker-containerd/config.toml"
    echo ""
    exit 1
  fi
}

# Pull the image
pull_image() {
  echo "==> Pulling image: $IMAGE"
  sudo $FC_CTR --address "$FC_SOCK" images pull \
    --snapshotter "$SNAPSHOTTER" \
    "$IMAGE"
  echo ""
}

# Run the container
run_container() {
  echo "==> Starting container in MicroVM..."
  echo ""
  echo "You are now inside a container running in a Firecracker MicroVM!"
  echo "Type 'exit' to stop the container and MicroVM."
  echo ""
  echo "----------------------------------------------"
  
  sudo $FC_CTR --address "$FC_SOCK" run \
    --snapshotter "$SNAPSHOTTER" \
    --runtime "$RUNTIME" \
    --rm \
    --tty \
    --net-host \
    "$IMAGE" \
    "$CONTAINER_NAME" \
    $COMMAND
}

# Main
main() {
  check_daemon
  pull_image
  run_container
}

main
