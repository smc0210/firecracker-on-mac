#!/usr/bin/env bash
# Install Firecracker (aarch64/x86_64) inside Lima L1 VM for M3 Mac Firecracker lab.
# Run this script inside the Lima VM: limactl shell fc-lab
# Usage (from project root inside Lima): ./scripts/microvm/install-firecracker.sh

set -euo pipefail

RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  aarch64|arm64) ARCH=aarch64 ;;
  x86_64|amd64)  ARCH=x86_64 ;;
  *) echo "Unsupported arch: $ARCH (use aarch64 or x86_64)"; exit 1 ;;
esac

# Wait for apt lock (e.g. cloud-init or another apt process after Lima boot)
wait_for_apt() {
  local max=60
  while true; do
    if ! sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null; then
      break
    fi
    ((max--)) || { echo "Timeout waiting for apt lock. Run: sudo kill 1642 (or the holding PID), then re-run this script."; exit 1; }
    echo "==> Waiting for apt lock to be released..."
    sleep 2
  done
}

echo "==> Installing dependencies (curl, tar, acl)..."
wait_for_apt
sudo apt-get update -qq
sudo apt-get install -y curl tar acl

echo "==> Granting current user access to /dev/kvm..."
if [[ -e /dev/kvm ]]; then
  sudo setfacl -m "u:${USER}:rw" /dev/kvm
  sudo usermod -aG kvm "$USER"
  echo "==> User $USER added to group 'kvm' (persists across reboots)."
  echo "    If this shell was already open, run: newgrp kvm   (or exit and limactl shell fc-lab again)."
else
  echo "WARNING: /dev/kvm not found. Nested virtualization may be disabled (e.g. need Lima with nestedVirtualization: true on M3)."
fi

echo "==> Resolving latest Firecracker release..."
LATEST_URL=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${RELEASE_URL}/latest")
LATEST=$(basename "$LATEST_URL")
TARBALL="firecracker-${LATEST}-${ARCH}.tgz"
RELEASE_DIR="release-${LATEST}-${ARCH}"

echo "==> Downloading Firecracker ${LATEST} (${ARCH})..."
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
curl -fsSL "${RELEASE_URL}/download/${LATEST}/${TARBALL}" -o "${WORKDIR}/${TARBALL}"

echo "==> Extracting and installing binaries..."
tar -xzf "${WORKDIR}/${TARBALL}" -C "$WORKDIR"
sudo mv "${WORKDIR}/${RELEASE_DIR}/firecracker-${LATEST}-${ARCH}" /usr/local/bin/firecracker
sudo mv "${WORKDIR}/${RELEASE_DIR}/jailer-${LATEST}-${ARCH}" /usr/local/bin/jailer
sudo chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer

echo "==> Verifying installation..."
firecracker --version
echo "Done. Firecracker is installed at /usr/local/bin/firecracker"
