#!/bin/bash
#
# HaikuOS R1/beta5 VM provisioning on Incus.
#
# Unlike the BSDs, Haiku uses a graphical installer — there is no text-mode
# or serial console installer. This script handles:
#   Phase 1: VM creation, ISO download, boot from ISO (automated)
#   Phase 2: Graphical installation via VGA console (MANUAL — user required)
#   Phase 3: Post-install SSH + build tools setup (automated)
#
# Usage:
#   bash provision-haiku.sh [VM_NAME] [TARGET_NODE] [ISO_PATH]
#   bash provision-haiku.sh --post-install VM_NAME [IP]
#
# Examples:
#   bash provision-haiku.sh                          # haiku-build on any node
#   bash provision-haiku.sh haiku-test star-01
#   bash provision-haiku.sh haiku-build star-01 /tmp/haiku-r1beta5-x86_64-anyboot.iso
#   bash provision-haiku.sh --post-install haiku-build 10.99.0.50
#
# After running this script:
#   1. Connect to VGA console:  incus console VM_NAME --type=vga
#      (opens a SPICE viewer — install virt-viewer/remote-viewer)
#   2. In the Haiku live desktop, open "Installer" from the Desktop
#   3. Open DriveSetup, initialize the target disk (GUID Partition Map)
#   4. Create a BFS partition, format it
#   5. Close DriveSetup, select source & destination, click "Begin"
#   6. After install completes, click "Restart"
#   7. Once rebooted from disk, run:
#        bash provision-haiku.sh --post-install VM_NAME
#
set -euo pipefail

# --- Parse arguments ---
if [ "${1:-}" = "--post-install" ]; then
    POST_INSTALL=true
    VM_NAME="${2:-haiku-build}"
    shift 2 || true
else
    POST_INSTALL=false
    VM_NAME="${1:-haiku-build}"
    TARGET="${2:-}"
    ISO_PATH="${3:-/tmp/haiku-r1beta5-x86_64-anyboot.iso}"
fi

ISO_URL="https://ftp.osuosl.org/pub/haiku/r1beta5/haiku-r1beta5-x86_64-anyboot.iso"
ISO_SHA256="22ae312a38e98083718b6984186e753d15806bd6ea44542144fdcef42c4dcb69"

# ===========================================================================
# POST-INSTALL: Enable SSH and install build tools
# ===========================================================================
if [ "$POST_INSTALL" = true ]; then
    echo "=== Post-install setup for ${VM_NAME} ==="

    # Haiku has no Incus agent, so 'incus list' cannot detect the IP.
    # We find the IP by looking up the VM's MAC in the ARP table or
    # via the user-supplied IP argument.
    IP="${3:-}"
    MAC=$(incus config get "$VM_NAME" volatile.eth0.hwaddr 2>/dev/null || true)

    if [ -z "$IP" ] && [ -n "$MAC" ]; then
        echo "[1/4] Discovering VM IP via ARP (MAC=$MAC) ..."
        IP=$(arp -an 2>/dev/null | grep -i "$MAC" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    fi

    if [ -z "$IP" ]; then
        echo "ERROR: Could not determine VM IP automatically."
        echo ""
        echo "  Haiku has no Incus agent, so IP detection requires ARP."
        echo "  You can find the IP from within the Haiku VM:"
        echo "    incus console $VM_NAME --type=vga"
        echo "  Then in Haiku's Terminal: ifconfig"
        echo ""
        echo "  Re-run with the IP:"
        echo "    bash provision-haiku.sh --post-install $VM_NAME <IP>"
        exit 1
    fi
    echo "  VM IP: $IP"

    echo "[2/4] Checking SSH connectivity ..."
    if timeout 5 bash -c "echo | nc -w 3 $IP 22" 2>/dev/null | grep -q SSH; then
        echo "  SSH already running on $IP:22"
    else
        echo ""
        echo "  *** SSH is not yet enabled on the Haiku VM. ***"
        echo ""
        echo "  Connect to VGA console and open Terminal:"
        echo "    incus console $VM_NAME --type=vga"
        echo ""
        echo "  In the Haiku Terminal, run:"
        echo "    pkgman install openssh"
        echo "    ssh-keygen -A"
        echo "    /boot/system/bin/sshd"
        echo "    mkdir -p ~/config/settings/boot/launch"
        echo "    ln -sf /boot/system/bin/sshd ~/config/settings/boot/launch/"
        echo ""
        echo "  After enabling SSH, re-run:"
        echo "    bash provision-haiku.sh --post-install $VM_NAME $IP"
        exit 1
    fi

    echo "[3/4] Setting password for 'user' account via SSH ..."
    # Haiku's default user is "user" with empty password.
    # sshd may reject empty-password logins; set a password first via VGA.
    echo "  (If SSH auth fails, set a password via VGA console first:"
    echo "   passwd user)"

    echo "[4/4] Installing build tools via SSH ..."
    ssh -o StrictHostKeyChecking=no user@"$IP" << 'TOOLS_EOF'
pkgman install -y cmake git ninja pkgconf curl wget make autoconf automake libtool python3.11 gcc

echo ""
echo "=== HaikuOS build tools installed ==="
uname -a
cmake --version | head -1
git --version
python3 --version 2>&1 || python3.11 --version 2>&1
gcc --version | head -1
df -h /boot
TOOLS_EOF

    echo ""
    echo "=== HaikuOS VM ready ==="
    echo "  Name:   $VM_NAME"
    echo "  IP:     $IP"
    echo "  SSH:    ssh user@$IP"
    echo "  OS:     HaikuOS R1/beta5 (x86_64)"
    exit 0
fi

# ===========================================================================
# PHASE 1: Create VM and boot from ISO
# ===========================================================================
echo "=== Provisioning HaikuOS VM: ${VM_NAME} ==="

# --- Download ISO if needed ---
if [ ! -f "$ISO_PATH" ]; then
    echo "[1/3] Downloading Haiku R1/beta5 ISO ..."
    curl -sL -o "$ISO_PATH" "$ISO_URL"
else
    echo "[1/3] Using existing ISO: $ISO_PATH"
fi

# Verify ISO size (should be ~1.4GB)
ISO_SIZE=$(stat -c%s "$ISO_PATH" 2>/dev/null || stat -f%z "$ISO_PATH" 2>/dev/null)
if [ "$ISO_SIZE" -lt 1000000000 ]; then
    echo "ERROR: ISO too small (${ISO_SIZE} bytes) — download may have failed"
    exit 1
fi

# Verify checksum
echo "  Verifying SHA256 checksum ..."
ACTUAL_SHA=$(sha256sum "$ISO_PATH" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$ISO_SHA256" ]; then
    echo "ERROR: SHA256 mismatch!"
    echo "  Expected: $ISO_SHA256"
    echo "  Got:      $ACTUAL_SHA"
    exit 1
fi
echo "  Checksum OK"

# --- Create VM ---
echo "[2/3] Creating VM ..."
TARGET_ARG=""
if [ -n "${TARGET:-}" ]; then
    TARGET_ARG="--target $TARGET"
fi

incus init "$VM_NAME" --vm --empty \
    -c limits.cpu=4 \
    -c limits.memory=4GiB \
    -c security.secureboot=false \
    -d root,size=50GiB \
    $TARGET_ARG

# Attach ISO as boot device
incus config device add "$VM_NAME" install-iso disk \
    source="$ISO_PATH" boot.priority=10

# --- Start VM ---
echo "[3/3] Starting VM (boots from ISO into Haiku live desktop) ..."
incus start "$VM_NAME"

echo ""
echo "============================================================"
echo "  HaikuOS VM created and booting from ISO."
echo ""
echo "  NEXT STEPS (graphical install required):"
echo ""
echo "  1. Connect to the VGA console:"
echo "       incus console $VM_NAME --type=vga"
echo "     (requires remote-viewer / virt-viewer installed)"
echo ""
echo "  2. In the Haiku live desktop:"
echo "     a. The Installer window should appear automatically"
echo "     b. Click 'Set up partitions...' to open DriveSetup"
echo "     c. Select the ~50GB QEMU HARDDISK → Disk → Initialize → GUID"
echo "     d. Select the raw partition → Partition → Create → BFS"
echo "     e. Close DriveSetup"
echo "     f. In Installer: select source (Haiku) and target (your partition)"
echo "     g. Click 'Begin' and wait for installation"
echo "     h. Click 'Restart' when done"
echo ""
echo "  3. After reboot, remove the ISO and enable SSH:"
echo "       incus stop $VM_NAME --force"
echo "       incus config device remove $VM_NAME install-iso"
echo "       incus start $VM_NAME"
echo "     Then via VGA console, open Terminal and run:"
echo "       pkgman install openssh"
echo "       ssh-keygen -A"
echo "       /boot/system/bin/sshd"
echo "       mkdir -p ~/config/settings/boot/launch"
echo "       ln -sf /boot/system/bin/sshd ~/config/settings/boot/launch/"
echo ""
echo "  4. Configure networking (Haiku uses virtio-net but may need"
echo "     manual DHCP configuration):"
echo "     In Haiku Terminal: ifconfig /dev/net/virtio_net/0 up"
echo "     Then: ifconfig /dev/net/virtio_net/0 auto"
echo "     Verify: ifconfig | grep 'inet addr'"
echo ""
echo "  5. Enable SSH and install build tools:"
echo "       bash provision-haiku.sh --post-install $VM_NAME <IP>"
echo "============================================================"
