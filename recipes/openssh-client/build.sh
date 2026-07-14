#!/usr/bin/env bash
# recipes/openssh-client/build.sh — build the portable OpenSSH client tools.
# Autotools (./configure) so cmake is not required.  The full source is
# built (openssh has no per-program build), then only the client binaries
# are installed with a curated `install` — this avoids `make install`'s
# host-key generation and privsep-dir creation, which need root and would
# pollute the host.  See openssh-server for sshd and its helpers.
set -euo pipefail

: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_SOURCE_DIR:?CVC_SOURCE_DIR must be set}"
: "${CVC_DEPS_PREFIX:=}"
: "${CVC_JOBS:=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

cd "${CVC_SOURCE_DIR}"

CONFIGURE_ARGS=(
    --prefix="${CVC_INSTALL_DIR}"
    --sysconfdir="${CVC_INSTALL_DIR}/etc/ssh"
    --with-privsep-path=/var/empty       # runtime path; not touched by this build
    --with-privsep-user=sshd
    --without-pam                         # key-based auth only; avoids libpam dep
    --without-selinux
    --without-kerberos5                   # keep the dep graph minimal
    --disable-security-key                # no libfido2 dep
)

# Link against our openssl/zlib recipes when present, and embed an $ORIGIN
# RPATH so the tools find libcrypto/libssl/libz next to themselves in any
# relocated prefix (bin/ and libexec/ are one level below <prefix>/lib).
if [[ -n "${CVC_DEPS_PREFIX}" && -d "${CVC_DEPS_PREFIX}/include/openssl" ]]; then
    CONFIGURE_ARGS+=(--with-ssl-dir="${CVC_DEPS_PREFIX}")
    export PKG_CONFIG_PATH="${CVC_DEPS_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    export LD_LIBRARY_PATH="${CVC_DEPS_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export LDFLAGS="${LDFLAGS:-} -Wl,-rpath,\$ORIGIN/../lib -Wl,-rpath,\$ORIGIN"
fi
if [[ -n "${CVC_DEPS_PREFIX}" && -f "${CVC_DEPS_PREFIX}/include/zlib.h" ]]; then
    CONFIGURE_ARGS+=(--with-zlib="${CVC_DEPS_PREFIX}")
fi

./configure "${CONFIGURE_ARGS[@]}"
make -j "${CVC_JOBS}"

# Curated install — client programs only.
mkdir -p "${CVC_INSTALL_DIR}/bin" "${CVC_INSTALL_DIR}/libexec" "${CVC_INSTALL_DIR}/etc/ssh"
for b in ssh scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan; do
    install -m 0755 "${b}" "${CVC_INSTALL_DIR}/bin/"
done
for h in ssh-keysign ssh-pkcs11-helper; do
    [[ -x "${h}" ]] && install -m 0755 "${h}" "${CVC_INSTALL_DIR}/libexec/" || true
done
[[ -f ssh_config ]] && install -m 0644 ssh_config "${CVC_INSTALL_DIR}/etc/ssh/ssh_config.sample" || true
