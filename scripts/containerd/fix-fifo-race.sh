#!/usr/bin/env bash
# Fix Firecracker Logger FIFO ENXIO error (os error 6) in firecracker-containerd.
#
# Root cause: The SDK's CreateLogFilesHandler opens the FIFO with O_RDWR then
# immediately closes it, so when Firecracker opens with O_WRONLY|O_NONBLOCK
# there's no reader → ENXIO.
#
# Fix (Approach C — handler chain swap):
#   1. Swap CreateLogFilesHandler with a no-op (prevent SDK's buggy open/close)
#   2. Open persistent O_RDONLY|O_NONBLOCK readers after each Mkfifo
#   3. Close readers in cleanup()
#
# See docs/fifo-enxio-fix.md for full analysis.
#
# Usage (from Lima VM): ./scripts/containerd/fix-fifo-race.sh
# This script patches, rebuilds, and reinstalls firecracker-containerd.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/patches/0001-fix-fifo-enxio.patch"
FC_CONTAINERD_DIR="${FC_CONTAINERD_DIR:-${HOME}/firecracker-containerd}"
SERVICE_GO="${FC_CONTAINERD_DIR}/runtime/service.go"
INSTALL_DIR="/usr/local/bin"

# Ensure Go is in PATH
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

# ── Validation ────────────────────────────────────────────────────────────────

if [[ ! -d "$FC_CONTAINERD_DIR" ]]; then
  echo "ERROR: firecracker-containerd directory not found: $FC_CONTAINERD_DIR"
  echo "Run install-fc-containerd.sh first."
  exit 1
fi

if [[ ! -f "$SERVICE_GO" ]]; then
  echo "ERROR: service.go not found: $SERVICE_GO"
  exit 1
fi

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "ERROR: Patch file not found: $PATCH_FILE"
  exit 1
fi

# ── Idempotency check ────────────────────────────────────────────────────────

if grep -q 'logFifoReader' "$SERVICE_GO"; then
  echo "==> FIFO fix already applied. Skipping patch."
  echo "==> To re-apply: cd $FC_CONTAINERD_DIR && git checkout runtime/service.go"
  exit 0
fi

# ── Apply patch ───────────────────────────────────────────────────────────────

echo "==> Applying FIFO ENXIO fix (Approach C: handler chain swap)..."
echo "==> Patch: $PATCH_FILE"
echo "==> Target: $SERVICE_GO"

cd "$FC_CONTAINERD_DIR"

if git apply --check "$PATCH_FILE" 2>&1; then
  git apply "$PATCH_FILE"
  echo "==> Patch applied via git apply."
else
  echo "==> git apply failed, trying with --3way..."
  if git apply --3way "$PATCH_FILE" 2>&1; then
    echo "==> Patch applied via git apply --3way."
  else
    echo "==> git apply --3way failed, trying patch -p1 --fuzz=3..."
    if patch -p1 --fuzz=3 --dry-run < "$PATCH_FILE"; then
      patch -p1 --fuzz=3 < "$PATCH_FILE"
      echo "==> Patch applied via patch -p1."
    else
      echo "ERROR: All patch methods failed. Source structure may have changed."
      echo "See docs/fifo-enxio-fix.md for manual patching instructions."
      exit 1
    fi
  fi
fi

# ── Verify patch ──────────────────────────────────────────────────────────────

echo "==> Verifying patch..."

verify_ok=true
if ! grep -q 'logFifoReader' "$SERVICE_GO"; then
  echo "ERROR: logFifoReader not found in service.go"
  verify_ok=false
fi
if ! grep -q 'metricsFifoReader' "$SERVICE_GO"; then
  echo "ERROR: metricsFifoReader not found in service.go"
  verify_ok=false
fi
if ! grep -q 'CreateLogFilesHandlerName' "$SERVICE_GO"; then
  echo "ERROR: CreateLogFilesHandler swap not found in service.go"
  verify_ok=false
fi

if [[ "$verify_ok" != true ]]; then
  echo "ERROR: Patch verification failed."
  exit 1
fi

echo "==> Patch verified: struct fields + handler swap + reader open + cleanup close"

# ── Rebuild ───────────────────────────────────────────────────────────────────

echo "==> Rebuilding firecracker-containerd..."
make all

# ── Reinstall binaries ────────────────────────────────────────────────────────

echo "==> Reinstalling binaries..."

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

if [[ -f "runtime/containerd-shim-aws-firecracker" ]]; then
  sudo cp runtime/containerd-shim-aws-firecracker "$INSTALL_DIR/"
  sudo chmod +x "$INSTALL_DIR/containerd-shim-aws-firecracker"
  echo "==> Installed containerd-shim-aws-firecracker"
fi

echo ""
echo "=============================================="
echo "  FIFO ENXIO fix applied and rebuilt"
echo "=============================================="
echo ""
echo "Changes applied to runtime/service.go:"
echo "  - CreateLogFilesHandler swapped with no-op"
echo "  - Persistent FIFO readers opened after Mkfifo"
echo "  - FIFO readers closed in cleanup()"
echo ""
echo "Next steps:"
echo "  1. Restart firecracker-containerd daemon"
echo "  2. Run a container to verify the fix"
echo ""
