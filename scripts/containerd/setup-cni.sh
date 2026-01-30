#!/usr/bin/env bash
# Setup CNI plugins for firecracker-containerd networking.
# This script installs standard CNI plugins and tc-redirect-tap for Firecracker VMs.
#
# Run this script inside the Lima VM: limactl shell fc-lab
# Usage (from project root inside Lima): ./scripts/containerd/setup-cni.sh
#
# Prerequisites:
#   - firecracker-containerd installed (run install-fc-containerd.sh first)

set -euo pipefail

# Configuration
CNI_PLUGINS_VERSION="v1.4.0"
CNI_BIN_DIR="/opt/cni/bin"
CNI_CONF_DIR="/etc/cni/conf.d"
FC_CONTAINERD_DIR="${HOME}/firecracker-containerd"

# Detect architecture
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  aarch64|arm64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=amd64 ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

echo "==> Architecture detected: $ARCH"

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

# Install standard CNI plugins
install_cni_plugins() {
  echo "==> Installing standard CNI plugins..."
  
  sudo mkdir -p "$CNI_BIN_DIR"
  sudo mkdir -p "$CNI_CONF_DIR"

  # Download CNI plugins
  CNI_TARBALL="cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz"
  CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/${CNI_TARBALL}"

  echo "==> Downloading CNI plugins ${CNI_PLUGINS_VERSION}..."
  curl -fsSL "$CNI_URL" -o "/tmp/${CNI_TARBALL}"

  echo "==> Extracting CNI plugins to ${CNI_BIN_DIR}..."
  sudo tar -xzf "/tmp/${CNI_TARBALL}" -C "$CNI_BIN_DIR"
  rm -f "/tmp/${CNI_TARBALL}"

  echo "==> Installed CNI plugins:"
  ls -la "$CNI_BIN_DIR"
}

# Build and install tc-redirect-tap from awslabs/tc-redirect-tap
install_tc_redirect_tap() {
  echo "==> Building tc-redirect-tap plugin..."

  # Check if Go is installed
  if ! command -v go &>/dev/null; then
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
  fi

  if ! command -v go &>/dev/null; then
    echo "ERROR: Go not found. Please run install-fc-containerd.sh first."
    exit 1
  fi

  # Check if already installed
  if [[ -f "$CNI_BIN_DIR/tc-redirect-tap" ]]; then
    echo "==> tc-redirect-tap already installed."
    return 0
  fi

  # Option 1: Check if tc-redirect-tap exists in firecracker-containerd build
  if [[ -d "$FC_CONTAINERD_DIR" ]]; then
    # Look for tc-redirect-tap in various possible locations
    for path in \
      "$FC_CONTAINERD_DIR/_submodules/tc-redirect-tap/cmd/tc-redirect-tap/tc-redirect-tap" \
      "$FC_CONTAINERD_DIR/bin/tc-redirect-tap" \
      "/usr/local/bin/tc-redirect-tap"; do
      if [[ -f "$path" ]]; then
        sudo cp "$path" "$CNI_BIN_DIR/"
        echo "==> tc-redirect-tap installed from $path"
        return 0
      fi
    done
  fi

  # Option 2: Build tc-redirect-tap from awslabs repository
  echo "==> Building tc-redirect-tap from awslabs/tc-redirect-tap..."
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR"

  git clone --depth 1 https://github.com/awslabs/tc-redirect-tap.git
  cd tc-redirect-tap

  go build -o tc-redirect-tap ./cmd/tc-redirect-tap
  sudo mv tc-redirect-tap "$CNI_BIN_DIR/"

  cd /
  rm -rf "$TMPDIR"

  echo "==> tc-redirect-tap installed."
}

# Create CNI network configuration for Firecracker
create_cni_config() {
  echo "==> Creating CNI network configuration..."

  # fcnet - point-to-point network with tc-redirect-tap
  sudo tee "${CNI_CONF_DIR}/fcnet.conflist" > /dev/null <<'EOF'
{
  "name": "fcnet",
  "cniVersion": "0.4.0",
  "plugins": [
    {
      "type": "ptp",
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.127.0/24",
        "resolvConf": "/etc/resolv.conf"
      }
    },
    {
      "type": "firewall"
    },
    {
      "type": "tc-redirect-tap"
    }
  ]
}
EOF

  echo "==> CNI configuration created: ${CNI_CONF_DIR}/fcnet.conflist"
}

# Enable IP forwarding and configure iptables
setup_network() {
  echo "==> Configuring network settings..."

  # Enable IP forwarding
  sudo sysctl -w net.ipv4.ip_forward=1
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null 2>&1 || true

  # Configure iptables for NAT (if not already configured)
  # Get the primary network interface
  PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
  
  if [[ -n "$PRIMARY_IF" ]]; then
    echo "==> Primary interface: $PRIMARY_IF"
    
    # Check if masquerade rule already exists
    if ! sudo iptables -t nat -C POSTROUTING -o "$PRIMARY_IF" -j MASQUERADE 2>/dev/null; then
      sudo iptables -t nat -A POSTROUTING -o "$PRIMARY_IF" -j MASQUERADE
      echo "==> Added NAT masquerade rule for $PRIMARY_IF"
    fi

    # Allow forwarding for established connections
    if ! sudo iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
      sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    fi

    # Allow forwarding from CNI subnet
    if ! sudo iptables -C FORWARD -s 192.168.127.0/24 -j ACCEPT 2>/dev/null; then
      sudo iptables -A FORWARD -s 192.168.127.0/24 -j ACCEPT
    fi

    echo "==> Firewall rules configured."
  else
    echo "WARNING: Could not determine primary network interface."
  fi
}

# Print summary
print_summary() {
  echo ""
  echo "=============================================="
  echo "  CNI Setup Complete"
  echo "=============================================="
  echo ""
  echo "Installed plugins in ${CNI_BIN_DIR}:"
  ls "$CNI_BIN_DIR" | grep -E '(ptp|host-local|firewall|tc-redirect-tap|bridge|loopback)' | sed 's/^/  - /'
  echo ""
  echo "Network configuration:"
  echo "  - Config: ${CNI_CONF_DIR}/fcnet.conflist"
  echo "  - Subnet: 192.168.127.0/24"
  echo "  - MicroVM will get IP: 192.168.127.2+"
  echo "  - Host gateway: 192.168.127.1"
  echo ""
  echo "IP forwarding and NAT are enabled."
  echo ""
  echo "VMs started with firecracker-containerd will automatically"
  echo "use the fcnet network and have internet access."
  echo ""
}

# Main
main() {
  echo "=============================================="
  echo "  CNI Plugin Installer for Firecracker"
  echo "  Architecture: $ARCH"
  echo "=============================================="
  echo ""

  install_cni_plugins
  install_tc_redirect_tap
  create_cni_config
  setup_network
  print_summary
}

main "$@"
