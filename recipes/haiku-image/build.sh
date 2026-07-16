#!/usr/bin/env bash
# recipes/haiku-image/build.sh — build a headless HaikuOS builder image.
#
# Haiku's Installer is graphical-only, so instead of installing interactively
# we build a fully pre-configured anyboot image from source:
#   1. clone haiku + buildtools (pinned)
#   2. build the cross-toolchain + a custom "builder-anyboot" jam profile
#      (UserBuildConfig: big disk, toolchain, OpenSSH, hostname)
#   3. inject an SSH authorized_keys + UserBootscript into the image's BFS
#      with Haiku's own bfs_shell (built from the same tree)
#   4. emit a portable qcow2 + the anyboot image + import docs
#
# Output is importable into Incus, LXD, Proxmox, or plain QEMU/libvirt with
# no VGA interaction — see README-import.md.
set -euo pipefail

: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_BUILD_DIR:?CVC_BUILD_DIR must be set}"
RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS="${CVC_JOBS:-$(nproc 2>/dev/null || echo 4)}"

HAIKU_REF="${HAIKU_REF:-r1beta5}"
BUILDTOOLS_REF="${BUILDTOOLS_REF:-r1beta5}"
HAIKU_REPO="${HAIKU_REPO:-https://github.com/haiku/haiku.git}"
BUILDTOOLS_REPO="${BUILDTOOLS_REPO:-https://github.com/haiku/buildtools.git}"

# ── 1. Host build dependencies (Debian/Ubuntu) ──────────────────────────
# Haiku's build needs a specific host toolchain plus xorriso/mtools for the
# image and qemu-img for the qcow2 conversion. Best-effort; if apt or sudo
# is unavailable the builder is expected to already carry these.
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y 2>/dev/null || true
    sudo apt-get install -y --no-install-recommends \
        git nasm bc autoconf automake texinfo flex bison gawk build-essential \
        unzip wget zip less zlib1g-dev libzstd-dev xorriso libtool gcc-multilib \
        mtools qemu-utils python3 2>/dev/null || true
fi

# ── 2. Clone sources ────────────────────────────────────────────────────
cd "${CVC_BUILD_DIR}"
[[ -d haiku ]]      || git clone --depth 1 --branch "${HAIKU_REF}"      "${HAIKU_REPO}"      haiku
[[ -d buildtools ]] || git clone --depth 1 --branch "${BUILDTOOLS_REF}" "${BUILDTOOLS_REPO}" buildtools

# Drop in the builder-anyboot profile.
cp "${RECIPE_DIR}/UserBuildConfig" haiku/build/jam/UserBuildConfig

# ── 3. Configure (builds the cross-toolchain) ───────────────────────────
cd haiku
if [[ ! -e generated/build/BuildConfig && ! -e generated.x86_64/build/BuildConfig ]]; then
    ./configure -j"${JOBS}" \
        --build-cross-tools x86_64 \
        --cross-tools-source ../buildtools
fi

# ── 4. Build the custom anyboot image ───────────────────────────────────
jam -q -j"${JOBS}" @builder-anyboot

ANYBOOT="$(ls -1 generated*/haiku-builder-anyboot.iso 2>/dev/null | head -1)"
[[ -n "${ANYBOOT}" ]] || ANYBOOT="$(ls -1 generated*/*anyboot*.iso 2>/dev/null | head -1)"
[[ -n "${ANYBOOT}" ]] || { echo "anyboot image not produced by jam" >&2; ls -R generated* | head -50; exit 1; }
echo "Built anyboot: ${ANYBOOT}"

# ── 5. Inject SSH key + UserBootscript via bfs_shell ────────────────────
# bfs_shell is a host tool that reads/writes BFS volumes directly. Build it
# from the same tree, then edit the image's BFS partition.
jam -q -j"${JOBS}" "<build>bfs_shell" 2>/dev/null || jam -q -j"${JOBS}" bfs_shell 2>/dev/null || true
BFS_SHELL="$(find generated* -type f -name bfs_shell -perm -u+x 2>/dev/null | head -1)"

INJ="${CVC_BUILD_DIR}/inject"
mkdir -p "${INJ}"
printf '%s\n' "${HAIKU_BUILDER_SSH_PUBKEY:-}" > "${INJ}/authorized_keys"
cp "${RECIPE_DIR}/UserBootscript" "${INJ}/UserBootscript"

if [[ -n "${BFS_SHELL}" ]]; then
    # The anyboot has an MBR; bfs_shell needs the BFS partition. Loop-mount
    # with -P to expose it (needs privilege — the star Linux builders have
    # passwordless sudo, same as the BSD provisioners).
    LOOP="$(sudo losetup -f -P --show "${ANYBOOT}" 2>/dev/null || true)"
    BFSPART=""
    [[ -n "${LOOP}" && -e "${LOOP}p1" ]] && BFSPART="${LOOP}p1"
    if [[ -n "${BFSPART}" ]]; then
        # bfs_shell scripted session: host paths are prefixed with ':'.
        sudo "${BFS_SHELL}" "${BFSPART}" <<BFSCMDS || echo "WARN: bfs_shell injection failed" >&2
mkdir home/.ssh
cp :${INJ}/authorized_keys home/.ssh/authorized_keys
cp :${INJ}/UserBootscript home/config/settings/boot/UserBootscript
sync
quit
BFSCMDS
        sudo losetup -d "${LOOP}" 2>/dev/null || true
    else
        echo "WARN: could not loop-mount the anyboot BFS partition; SSH key not injected." >&2
        echo "      Inject it post-import instead (see README-import.md)." >&2
    fi
else
    echo "WARN: bfs_shell not built; SSH key not injected (inject post-import)." >&2
fi

# ── 6. Stage outputs: portable qcow2 + anyboot + docs ───────────────────
mkdir -p "${CVC_INSTALL_DIR}"
if command -v qemu-img >/dev/null 2>&1; then
    qemu-img convert -f raw -O qcow2 "${ANYBOOT}" "${CVC_INSTALL_DIR}/haiku-builder.qcow2"
else
    cp "${ANYBOOT}" "${CVC_INSTALL_DIR}/haiku-builder.qcow2"  # raw fallback (still qemu-bootable)
fi
cp "${ANYBOOT}" "${CVC_INSTALL_DIR}/haiku-builder-anyboot.iso"
cp "${RECIPE_DIR}/metadata.yaml"     "${CVC_INSTALL_DIR}/metadata.yaml"
cp "${RECIPE_DIR}/README-import.md"  "${CVC_INSTALL_DIR}/README-import.md"

echo "Haiku builder image staged to ${CVC_INSTALL_DIR}:"
ls -lh "${CVC_INSTALL_DIR}"
