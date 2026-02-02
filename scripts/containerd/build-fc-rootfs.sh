#!/usr/bin/env bash
# Build firecracker-containerd rootfs image with fc-agent.
# This script builds a Debian-based root filesystem containing the firecracker-containerd agent
# and runC for running containers inside MicroVMs.
#
# Run this script inside the Lima VM: limactl shell fc-lab
# Usage (from project root inside Lima): ./scripts/containerd/build-fc-rootfs.sh
#
# Prerequisites:
#   - Docker installed and running
#   - firecracker-containerd cloned (run install-fc-containerd.sh first)

set -euo pipefail

# Configuration
FC_CONTAINERD_DIR="${HOME}/firecracker-containerd"
RUNTIME_DIR="/var/lib/firecracker-containerd/runtime"
OUTPUT_FILE="${RUNTIME_DIR}/default-rootfs.img"

echo "=============================================="
echo "  Firecracker-containerd Rootfs Builder"
echo "=============================================="
echo ""

# Check prerequisites
if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker not found. Please install Docker first."
  exit 1
fi

if ! docker info &>/dev/null; then
  echo "ERROR: Cannot connect to Docker daemon."
  echo "Try: sudo usermod -aG docker $USER && newgrp docker"
  exit 1
fi

if [[ ! -d "$FC_CONTAINERD_DIR" ]]; then
  echo "ERROR: firecracker-containerd not found at $FC_CONTAINERD_DIR"
  echo "Please run install-fc-containerd.sh first."
  exit 1
fi

# Build the image
echo "==> Building rootfs image (this may take several minutes)..."
cd "$FC_CONTAINERD_DIR"

# The image builder uses Docker to create a Debian-based rootfs
# containing fc-agent, runc, and overlay-init.
# STATIC_AGENT=1: agent must be statically linked because the rootfs uses
# Debian 11 (glibc 2.31), while the build host may have a newer glibc.
sg docker -c 'STATIC_AGENT=1 make image' || {
  echo ""
  echo "ERROR: Image build failed."
  echo ""
  echo "If you see permission errors, try:"
  echo "  newgrp docker"
  echo "  ./scripts/containerd/build-fc-rootfs.sh"
  exit 1
}

# Copy to runtime directory
echo "==> Installing rootfs image..."
sudo mkdir -p "$RUNTIME_DIR"
sudo cp tools/image-builder/rootfs.img "$OUTPUT_FILE"

# Set proper permissions
sudo chmod 644 "$OUTPUT_FILE"

# Show image info
echo ""
echo "=============================================="
echo "  Rootfs Build Complete"
echo "=============================================="
echo ""
echo "Image location: $OUTPUT_FILE"
echo "Image size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""
echo "The rootfs contains:"
echo "  - Debian base system"
echo "  - fc-agent (firecracker-containerd agent)"
echo "  - runc (container runtime)"
echo "  - overlay-init (read-only root with overlay)"
echo ""
echo "This image is configured for read-only operation with"
echo "a read-write overlay, allowing safe sharing among VMs."
echo ""
