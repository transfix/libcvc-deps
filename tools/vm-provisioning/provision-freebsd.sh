#!/bin/bash
#
# Fully automated FreeBSD 14.4 VM provisioning on Incus.
# Creates the VM from a pre-built cloud image, starts it,
# and installs the build toolchain.
#
# FreeBSD cloud images from images.linuxcontainers.org come
# pre-configured with DHCP, serial console, and root access
# via `incus exec`, so no manual install or ISO is needed.
#
# Usage:
#   bash provision-freebsd.sh [VM_NAME] [TARGET_NODE]
#
# Examples:
#   bash provision-freebsd.sh                     # freebsd-build on any node
#   bash provision-freebsd.sh freebsd-test star-00
#
set -euo pipefail

VM_NAME="${1:-freebsd-build}"
TARGET="${2:-}"

echo "=== Provisioning FreeBSD VM: ${VM_NAME} ==="

# --- Create VM from remote image ---
TARGET_ARG=""
if [ -n "$TARGET" ]; then
    TARGET_ARG="--target $TARGET"
fi

echo "[1/4] Creating VM from images:freebsd/14.4/default ..."
incus init images:freebsd/14.4/default "$VM_NAME" --vm \
    -c limits.cpu=4 \
    -c limits.memory=4GiB \
    -c security.secureboot=false \
    -d root,size=50GiB \
    $TARGET_ARG

echo "[2/4] Starting VM ..."
incus start "$VM_NAME"

echo "[3/4] Waiting for VM agent ..."
for i in $(seq 1 60); do
    if incus exec "$VM_NAME" -- true 2>/dev/null; then
        break
    fi
    sleep 5
done

# Verify agent is up
if ! incus exec "$VM_NAME" -- true 2>/dev/null; then
    echo "ERROR: VM agent not available after 5 minutes"
    exit 1
fi

echo "[4/4] Installing build tools ..."
incus exec "$VM_NAME" -- sh -c '
    pkg install -y \
        cmake git ninja pkgconf curl wget gmake \
        autoconf automake libtool \
        python3 py311-pip \
        llvm18 gcc14

    echo ""
    echo "=== FreeBSD build tools installed ==="
    uname -sr
    cmake --version | head -1
    git --version
    ninja --version
    gcc14 --version | head -1
    clang --version | head -1
    python3 --version
'

IP=$(incus list "$VM_NAME" -f csv -c 4 | cut -d' ' -f1)
echo ""
echo "=== FreeBSD VM ready ==="
echo "  Name:   ${VM_NAME}"
echo "  IP:     ${IP}"
echo "  Access: incus exec ${VM_NAME} -- sh"
echo "  OS:     $(incus exec "$VM_NAME" -- uname -sr)"
