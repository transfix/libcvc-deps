#!/usr/bin/env bash
# recipes/automake/build.sh — build GNU Automake from source.
set -euo pipefail

: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_SOURCE_DIR:?CVC_SOURCE_DIR must be set}"
: "${CVC_JOBS:=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# GNU make + versioned autotools on BSD.
MAKE=make
case "$(uname -s)" in
    FreeBSD|OpenBSD|NetBSD|DragonFly)
        if command -v gmake >/dev/null 2>&1; then
            MAKE=gmake
        fi
        # OpenBSD/NetBSD ports install autoconf as autoconf-<VER>.
        # Point configure at the latest ≥2.65 present on PATH so the
        # "Autoconf 2.65 or better is required" check passes.
        if [[ -z "${AUTOCONF:-}" ]]; then
            for candidate in autoconf-2.72 autoconf-2.71 autoconf-2.69 autoconf; do
                if command -v "${candidate}" >/dev/null 2>&1; then
                    export AUTOCONF="${candidate}"
                    break
                fi
            done
        fi
        if [[ -z "${AUTOM4TE:-}" ]]; then
            for candidate in autom4te-2.72 autom4te-2.71 autom4te-2.69 autom4te; do
                if command -v "${candidate}" >/dev/null 2>&1; then
                    export AUTOM4TE="${candidate}"
                    break
                fi
            done
        fi
        ;;
esac

# autom4te (invoked by autoconf, which automake's configure runs to prove the
# toolchain works) resolves m4 as $M4 or the hard-coded /usr/bin/m4 — it never
# consults PATH. On minimal Linux builders /usr/bin/m4 does not exist, and on
# the BSDs it is the non-GNU base m4, so without help autoconf's self-test dies
# with "need GNU m4 1.4 or later". Point $M4 at the GNU m4 shipped in this
# build's dependency closure (prefixed onto PATH by cvcpkg); prefer a gm4 name
# where the platform installs GNU m4 under it.
if [[ -z "${M4:-}" ]]; then
    for candidate in gm4 m4; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            export M4="$(command -v "${candidate}")"
            break
        fi
    done
fi

cd "${CVC_SOURCE_DIR}"

./configure \
    --prefix="${CVC_INSTALL_DIR}"

"${MAKE}" -j "${CVC_JOBS}"
"${MAKE}" install
