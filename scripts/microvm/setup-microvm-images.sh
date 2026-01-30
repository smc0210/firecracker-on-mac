#!/usr/bin/env bash
# Download Firecracker MicroVM kernel and rootfs from official CI (S3).
# Uses same discovery as Firecracker getting-started: latest release -> list S3 -> download.
# Run inside Lima VM: limactl shell fc-lab
# Usage (from project root inside Lima): ./scripts/microvm/setup-microvm-images.sh

set -euo pipefail

RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
# Path-style URLs to avoid SSL cert mismatch (bucket.s3.amazonaws.com often fails)
S3_BASE="https://s3.amazonaws.com/spec.ccfc.min"
ARCH="${ARCH:-$(uname -m)}"
IMAGES_DIR="${MICROVM_IMAGES_DIR:-$HOME/microvm-images}"

echo "==> Resolving latest Firecracker CI version..."
LATEST_TAG=$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${RELEASE_URL}/latest")")
# CI artifacts use major.minor (e.g. v1.14) not full tag (v1.14.1)
CI_VERSION="${LATEST_TAG%.*}"

echo "==> Creating images directory: $IMAGES_DIR"
mkdir -p "$IMAGES_DIR"
cd "$IMAGES_DIR"

# aarch64 needs PE/Image format; x86_64 uses ELF vmlinux. Prefer Image-* for aarch64.
KERNEL_KEY=""
if [ "$ARCH" = "aarch64" ]; then
  echo "==> Discovering latest kernel (firecracker-ci/$CI_VERSION/$ARCH/Image-*)..."
  KERNEL_KEYS=$(curl -fsSL "${S3_BASE}/?list-type=2&prefix=firecracker-ci/${CI_VERSION}/${ARCH}/Image-" \
    | grep -oE '<Key>[^<]+</Key>' | sed 's/<Key>//;s/<\/Key>//' | grep -v '\.config$' | sort -V) || true
  KERNEL_KEY=$(echo "$KERNEL_KEYS" | tail -1)
fi
if [ -z "$KERNEL_KEY" ]; then
  echo "==> Discovering latest kernel (firecracker-ci/$CI_VERSION/$ARCH/vmlinux-*)..."
  KERNEL_KEYS=$(curl -fsSL "${S3_BASE}/?list-type=2&prefix=firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-" \
    | grep -oE '<Key>[^<]+</Key>' | sed 's/<Key>//;s/<\/Key>//' | grep -v '\.config$' | sort -V) || true
  KERNEL_KEY=$(echo "$KERNEL_KEYS" | tail -1)
fi
[ -z "$KERNEL_KEY" ] && { echo "ERROR: No kernel found in CI for $CI_VERSION $ARCH"; exit 1; }

echo "==> Downloading kernel: $KERNEL_KEY"
curl -fsSL "${S3_BASE}/${KERNEL_KEY}" -o kernel-arm64.bin

echo "==> Discovering latest Ubuntu rootfs (squashfs)..."
UBUNTU_KEYS=$(curl -fsSL "${S3_BASE}/?list-type=2&prefix=firecracker-ci/${CI_VERSION}/${ARCH}/ubuntu-" \
  | grep -oE '<Key>[^<]+</Key>' | sed 's/<Key>//;s/<\/Key>//' | grep '\.squashfs$' | sort -V)
UBUNTU_KEY=$(echo "$UBUNTU_KEYS" | tail -1)

if [ -n "$UBUNTU_KEY" ]; then
  UBUNTU_FILE=$(basename "$UBUNTU_KEY" .squashfs)
  echo "==> Downloading rootfs (squashfs): $UBUNTU_KEY"
  curl -fsSL "${S3_BASE}/${UBUNTU_KEY}" -o "${UBUNTU_FILE}.squashfs.upstream"
  echo "==> Converting squashfs -> ext4 (unsquashfs + mkfs.ext4)..."
  command -v unsquashfs >/dev/null 2>&1 || sudo apt-get install -y squashfs-tools
  sudo rm -rf squashfs-root
  unsquashfs -f -d squashfs-root "${UBUNTU_FILE}.squashfs.upstream"
  ssh-keygen -f ubuntu.id_rsa -N "" -q
  mkdir -p squashfs-root/root/.ssh
  cp ubuntu.id_rsa.pub squashfs-root/root/.ssh/authorized_keys
  sudo chown -R root:root squashfs-root
  truncate -s 1G rootfs.ext4
  sudo mkfs.ext4 -d squashfs-root -F rootfs.ext4
  mv ubuntu.id_rsa "${UBUNTU_FILE}.id_rsa"
  chmod 600 "${UBUNTU_FILE}.id_rsa"
  sudo rm -rf squashfs-root "${UBUNTU_FILE}.squashfs.upstream"
  SSH_KEY_NAME="${UBUNTU_FILE}.id_rsa"
else
  echo "==> No ubuntu squashfs found; checking for pre-built ext4..."
  EXT4_KEYS=$(curl -fsSL "${S3_BASE}/?list-type=2&prefix=firecracker-ci/${CI_VERSION}/${ARCH}/" \
    | grep -oE '<Key>[^<]+</Key>' | sed 's/<Key>//;s/<\/Key>//' | grep '\.ext4$' | sort -V)
  EXT4_KEY=$(echo "$EXT4_KEYS" | tail -1)
  if [ -n "$EXT4_KEY" ]; then
    curl -fsSL "${S3_BASE}/${EXT4_KEY}" -o rootfs.ext4
    SSH_KEY_NAME=""
  else
    echo "ERROR: No ubuntu squashfs or ext4 found in CI for $CI_VERSION $ARCH"
    exit 1
  fi
fi

echo "==> Writing vm_config.json..."
cat > vm_config.json << 'EOF'
{
  "boot-source": {
    "kernel_image_path": "kernel-arm64.bin",
    "boot_args": "keep_bootcon console=ttyS0 reboot=k panic=1 pci=off",
    "initrd_path": null
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 512,
    "smt": false
  }
}
EOF

echo "Done. Files in $IMAGES_DIR:"
ls -la kernel-arm64.bin rootfs.ext4 vm_config.json 2>/dev/null || true
[ -n "$SSH_KEY_NAME" ] && [ -f "$SSH_KEY_NAME" ] && ls -la "$SSH_KEY_NAME"
echo ""
echo "Run MicroVM from this directory:"
echo "  cd $IMAGES_DIR"
echo "  firecracker --no-api --config-file vm_config.json"
echo "  (login: root / root; SSH key: $IMAGES_DIR/$SSH_KEY_NAME if present)"
