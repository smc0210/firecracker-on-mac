#!/usr/bin/env bash
# Install firecracker-containerd (aarch64/x86_64) inside Lima L1 VM for M3 Mac Firecracker lab.
# This script installs containerd, Go, and builds firecracker-containerd from source.
#
# Run this script inside the Lima VM: limactl shell fc-lab
# Usage (from project root inside Lima): ./scripts/containerd/install-fc-containerd.sh
#
# Prerequisites:
#   - Firecracker already installed (run install-firecracker.sh first)
#   - Docker installed in Lima VM (for building rootfs image)

set -euo pipefail

# Configuration
FC_CONTAINERD_REPO="https://github.com/firecracker-microvm/firecracker-containerd.git"
FC_CONTAINERD_DIR="${HOME}/firecracker-containerd"
GO_VERSION="1.23.0"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/firecracker-containerd"
RUNTIME_DIR="/var/lib/firecracker-containerd/runtime"
SNAPSHOTTER_DIR="/var/lib/firecracker-containerd/snapshotter/devmapper"

# Detect architecture
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  aarch64|arm64) ARCH=aarch64; GO_ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x86_64; GO_ARCH=amd64 ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

echo "==> Architecture detected: $ARCH (Go: $GO_ARCH)"

# Wait for apt lock
wait_for_apt() {
  local max=60
  while true; do
    if ! sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null; then
      break
    fi
    ((max--)) || { echo "Timeout waiting for apt lock."; exit 1; }
    echo "==> Waiting for apt lock..."
    sleep 2
  done
}

# Install system dependencies
install_dependencies() {
  echo "==> Installing system dependencies..."
  wait_for_apt
  sudo apt-get update -qq
  sudo apt-get install -y \
    curl \
    git \
    make \
    gcc \
    e2fsprogs \
    util-linux \
    bc \
    gnupg \
    dmsetup \
    acl \
    iptables \
    iproute2
}

# Install Docker if not present
install_docker() {
  if command -v docker &>/dev/null; then
    echo "==> Docker already installed: $(docker --version)"
    return 0
  fi

  echo "==> Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  echo "==> Docker installed. You may need to log out and back in for group membership."
}

# Install Go
install_go() {
  if command -v go &>/dev/null; then
    CURRENT_GO=$(go version | grep -oP 'go\d+\.\d+' | head -1)
    echo "==> Go already installed: $CURRENT_GO"
    # Check if version is sufficient (1.23+)
    GO_MAJOR=$(echo "$CURRENT_GO" | grep -oP '\d+' | head -1)
    GO_MINOR=$(echo "$CURRENT_GO" | grep -oP '\d+' | tail -1)
    if [[ "$GO_MAJOR" -ge 1 ]] && [[ "$GO_MINOR" -ge 23 ]]; then
      echo "==> Go version is sufficient."
      return 0
    fi
    echo "==> Go version is too old, upgrading..."
  fi

  echo "==> Installing Go ${GO_VERSION}..."
  GO_TARBALL="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  curl -fsSL "https://go.dev/dl/${GO_TARBALL}" -o "/tmp/${GO_TARBALL}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "/tmp/${GO_TARBALL}"
  rm -f "/tmp/${GO_TARBALL}"

  # Add to PATH if not already
  if ! grep -q '/usr/local/go/bin' ~/.bashrc; then
    echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.bashrc
  fi
  export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

  echo "==> Go installed: $(go version)"
}

# Clone and build firecracker-containerd
build_fc_containerd() {
  echo "==> Cloning firecracker-containerd..."
  if [[ -d "$FC_CONTAINERD_DIR" ]]; then
    echo "==> Directory exists, pulling latest..."
    cd "$FC_CONTAINERD_DIR"
    git pull --recurse-submodules
  else
    git clone --recurse-submodules "$FC_CONTAINERD_REPO" "$FC_CONTAINERD_DIR"
    cd "$FC_CONTAINERD_DIR"
  fi

  echo "==> Building firecracker-containerd (this may take several minutes)..."
  # Ensure Go is in PATH
  export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

  # Build all components
  # Note: For ARM64, some modifications might be needed
  make all

  echo "==> Installing firecracker-containerd binaries..."
  
  # Install binaries manually (make install may fail silently)
  # firecracker-containerd and firecracker-ctr
  if [[ -f "firecracker-control/cmd/containerd/firecracker-containerd" ]]; then
    sudo cp firecracker-control/cmd/containerd/firecracker-containerd "$INSTALL_DIR/"
    sudo chmod +x "$INSTALL_DIR/firecracker-containerd"
    echo "==> Installed firecracker-containerd"
  fi

  if [[ -f "firecracker-control/cmd/containerd/firecracker-ctr" ]]; then
    sudo cp firecracker-control/cmd/containerd/firecracker-ctr "$INSTALL_DIR/"
    sudo chmod +x "$INSTALL_DIR/firecracker-ctr"
    echo "==> Installed firecracker-ctr"
  fi

  # Runtime shim
  if [[ -f "runtime/containerd-shim-aws-firecracker" ]]; then
    sudo cp runtime/containerd-shim-aws-firecracker "$INSTALL_DIR/"
    sudo chmod +x "$INSTALL_DIR/containerd-shim-aws-firecracker"
    echo "==> Installed containerd-shim-aws-firecracker"
  fi

  # Verify installation
  echo "==> Verifying installation..."
  ls -la "$INSTALL_DIR" | grep -E "(firecracker-containerd|firecracker-ctr|containerd-shim)"
}

# Build rootfs image with fc-agent
build_rootfs_image() {
  echo "==> Building rootfs image with fc-agent..."
  cd "$FC_CONTAINERD_DIR"

  # Build the image (requires Docker)
  sg docker -c 'make image' || {
    echo "WARNING: Could not build image. Make sure Docker is running and you're in the docker group."
    echo "Try: newgrp docker && ./scripts/containerd/install-fc-containerd.sh"
    return 1
  }

  # Copy rootfs to runtime directory
  sudo mkdir -p "$RUNTIME_DIR"
  sudo cp tools/image-builder/rootfs.img "$RUNTIME_DIR/default-rootfs.img"
  echo "==> Rootfs image installed to $RUNTIME_DIR/default-rootfs.img"
}

# Download kernel for firecracker-containerd
download_kernel() {
  echo "==> Downloading kernel for firecracker-containerd..."
  sudo mkdir -p "$RUNTIME_DIR"

  # Use existing kernel from setup-microvm-images.sh if available
  if [[ -f ~/microvm-images/kernel-arm64.bin ]]; then
    sudo cp ~/microvm-images/kernel-arm64.bin "$RUNTIME_DIR/default-vmlinux.bin"
    echo "==> Using existing kernel from ~/microvm-images/"
  else
    # Download appropriate kernel
    if [[ "$ARCH" == "aarch64" ]]; then
      KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.11/aarch64/vmlinux-5.10"
    else
      KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"
    fi
    sudo curl -fsSL "$KERNEL_URL" -o "$RUNTIME_DIR/default-vmlinux.bin"
    echo "==> Kernel downloaded to $RUNTIME_DIR/default-vmlinux.bin"
  fi
}

# Setup devmapper thin pool for snapshotter
setup_devmapper() {
  echo "==> Setting up devmapper thin pool..."
  sudo mkdir -p "$SNAPSHOTTER_DIR"

  POOL_NAME="fc-dev-thinpool"

  # Check if pool already exists
  if sudo dmsetup info "$POOL_NAME" &>/dev/null; then
    echo "==> Thin pool $POOL_NAME already exists."
    return 0
  fi

  # Create sparse files for data and metadata
  if [[ ! -f "${SNAPSHOTTER_DIR}/data" ]]; then
    sudo touch "${SNAPSHOTTER_DIR}/data"
    sudo truncate -s 100G "${SNAPSHOTTER_DIR}/data"
  fi

  if [[ ! -f "${SNAPSHOTTER_DIR}/metadata" ]]; then
    sudo touch "${SNAPSHOTTER_DIR}/metadata"
    sudo truncate -s 2G "${SNAPSHOTTER_DIR}/metadata"
  fi

  # Setup loop devices
  DATADEV=$(sudo losetup --output NAME --noheadings --associated "${SNAPSHOTTER_DIR}/data" || true)
  if [[ -z "$DATADEV" ]]; then
    DATADEV=$(sudo losetup --find --show "${SNAPSHOTTER_DIR}/data")
  fi

  METADEV=$(sudo losetup --output NAME --noheadings --associated "${SNAPSHOTTER_DIR}/metadata" || true)
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

  sudo dmsetup create "$POOL_NAME" --table "$THINP_TABLE" || {
    echo "==> Thin pool creation failed, attempting reload..."
    sudo dmsetup reload "$POOL_NAME" --table "$THINP_TABLE" || true
  }

  echo "==> Devmapper thin pool $POOL_NAME created."
}

# Create firecracker-containerd configuration
create_config() {
  echo "==> Creating firecracker-containerd configuration..."
  sudo mkdir -p "$CONFIG_DIR"
  sudo mkdir -p /var/lib/firecracker-containerd/containerd
  sudo mkdir -p /var/lib/firecracker-containerd/shim-base
  sudo mkdir -p /run/firecracker-containerd

  # Main containerd config
  sudo tee "${CONFIG_DIR}/config.toml" > /dev/null <<EOF
version = 2
disabled_plugins = ["io.containerd.grpc.v1.cri"]
root = "/var/lib/firecracker-containerd/containerd"
state = "/run/firecracker-containerd"

[grpc]
  address = "/run/firecracker-containerd/containerd.sock"

[plugins]
  [plugins."io.containerd.snapshotter.v1.devmapper"]
    pool_name = "fc-dev-thinpool"
    base_image_size = "10GB"
    root_path = "${SNAPSHOTTER_DIR}"

[debug]
  level = "debug"
EOF

  # Runtime config
  # Note: cpu_template is x86-specific (T2, C3). For ARM64, we omit it.
  if [[ "$ARCH" == "aarch64" ]]; then
    sudo tee "${CONFIG_DIR}/firecracker-runtime.json" > /dev/null <<EOF
{
  "firecracker_binary_path": "/usr/local/bin/firecracker",
  "kernel_image_path": "${RUNTIME_DIR}/default-vmlinux.bin",
  "kernel_args": "console=ttyS0 noapic reboot=k panic=1 pci=off nomodules ro systemd.unified_cgroup_hierarchy=0 systemd.journald.forward_to_console systemd.unit=firecracker.target init=/sbin/overlay-init",
  "root_drive": "${RUNTIME_DIR}/default-rootfs.img",
  "log_levels": ["debug"],
  "debug": true,
  "default_network_interfaces": [
    {
      "CNIConfig": {
        "NetworkName": "fcnet",
        "InterfaceName": "veth0"
      }
    }
  ]
}
EOF
  else
    sudo tee "${CONFIG_DIR}/firecracker-runtime.json" > /dev/null <<EOF
{
  "firecracker_binary_path": "/usr/local/bin/firecracker",
  "kernel_image_path": "${RUNTIME_DIR}/default-vmlinux.bin",
  "kernel_args": "console=ttyS0 noapic reboot=k panic=1 pci=off nomodules ro systemd.unified_cgroup_hierarchy=0 systemd.journald.forward_to_console systemd.unit=firecracker.target init=/sbin/overlay-init",
  "root_drive": "${RUNTIME_DIR}/default-rootfs.img",
  "cpu_template": "T2",
  "log_levels": ["debug"],
  "debug": true,
  "default_network_interfaces": [
    {
      "CNIConfig": {
        "NetworkName": "fcnet",
        "InterfaceName": "veth0"
      }
    }
  ]
}
EOF
  fi

  # Symlink for default config path
  sudo ln -sf "${CONFIG_DIR}/firecracker-runtime.json" /etc/containerd/firecracker-runtime.json 2>/dev/null || \
    sudo mkdir -p /etc/containerd && sudo ln -sf "${CONFIG_DIR}/firecracker-runtime.json" /etc/containerd/firecracker-runtime.json

  echo "==> Configuration files created in $CONFIG_DIR"
}

# Print summary and next steps
print_summary() {
  echo ""
  echo "=============================================="
  echo "  firecracker-containerd installation complete"
  echo "=============================================="
  echo ""
  echo "Installed components:"
  echo "  - firecracker-containerd (containerd with FC plugin)"
  echo "  - firecracker-ctr (CLI tool)"
  echo "  - containerd-shim-aws-firecracker (runtime shim)"
  echo "  - Devmapper thin pool: fc-dev-thinpool"
  echo "  - Rootfs with fc-agent: ${RUNTIME_DIR}/default-rootfs.img"
  echo ""
  echo "Configuration files:"
  echo "  - ${CONFIG_DIR}/config.toml"
  echo "  - ${CONFIG_DIR}/firecracker-runtime.json"
  echo ""
  echo "Next steps:"
  echo "  1. Install CNI plugins: ./scripts/containerd/setup-cni.sh"
  echo "  2. Start firecracker-containerd:"
  echo "     sudo firecracker-containerd --config ${CONFIG_DIR}/config.toml"
  echo ""
  echo "  3. In another terminal, pull an image and run a container:"
  echo "     sudo firecracker-ctr --address /run/firecracker-containerd/containerd.sock \\"
  echo "       images pull --snapshotter devmapper docker.io/library/alpine:latest"
  echo ""
  echo "     sudo firecracker-ctr --address /run/firecracker-containerd/containerd.sock \\"
  echo "       run --snapshotter devmapper --runtime aws.firecracker --rm --tty \\"
  echo "       docker.io/library/alpine:latest test-alpine sh"
  echo ""
}

# Main installation flow
main() {
  echo "=============================================="
  echo "  firecracker-containerd Installer"
  echo "  Architecture: $ARCH"
  echo "=============================================="
  echo ""

  # Check if firecracker is installed
  if ! command -v firecracker &>/dev/null; then
    echo "ERROR: Firecracker not found. Please run install-firecracker.sh first."
    exit 1
  fi

  install_dependencies
  install_docker
  install_go
  build_fc_containerd
  download_kernel
  build_rootfs_image
  setup_devmapper
  create_config
  print_summary
}

main "$@"
