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
# the BSDs it is the non-GNU base m4, so autoconf's self-test dies with "need
# GNU m4 1.4 or later" → "the installed version of autoconf does not work".
#
# Point $M4 at the GNU m4 cvcpkg installed into this build's closure. Address it
# by prefix rather than PATH, and set it UNCONDITIONALLY: the fleet builder runs
# build scripts under `os.environ.copy()`, and its environment already exports a
# stale M4 (an absolute /usr/bin/m4 that does not exist on the builder), so a
# "only if unset" guard would leave that poisoned value in place and PATH order
# would not save us.  Fall back to a GNU m4 on PATH (gm4 on the BSDs) only when
# the closure somehow lacks one.
m4_bin=""
for root in "${CVC_BUILD_PREFIX:-}" "${CVC_DEPS_PREFIX:-}" "${CVC_INSTALL_DIR:-}"; do
    if [[ -n "${root}" && -x "${root}/bin/m4" ]]; then
        m4_bin="${root}/bin/m4"
        break
    fi
done
if [[ -z "${m4_bin}" ]]; then
    for candidate in gm4 m4; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            m4_bin="$(command -v "${candidate}")"
            break
        fi
    done
fi
if [[ -n "${m4_bin}" ]]; then
    export M4="${m4_bin}"
fi

# --- diagnostics (cvc.4): the fleet keeps reporting "autoconf does not work"
# even with m4 in the closure; surface exactly what m4 resolved to and prove it
# runs, so the build-log tail explains a failure instead of hiding it. ---
echo "[automake/build.sh] CVC_BUILD_PREFIX=[${CVC_BUILD_PREFIX:-UNSET}]"
echo "[automake/build.sh] CVC_DEPS_PREFIX=[${CVC_DEPS_PREFIX:-UNSET}]"
echo "[automake/build.sh] M4=[${M4:-UNSET}]  autom4te=[$(command -v autom4te || echo none)]  autoconf=[$(command -v autoconf || echo none)]"
if [[ -n "${M4:-}" ]]; then
    echo "[automake/build.sh] \$M4 --version:"; "${M4}" --version 2>&1 | head -1 || echo "  (M4 failed to run)"
fi

cd "${CVC_SOURCE_DIR}"

if ! ./configure --prefix="${CVC_INSTALL_DIR}"; then
    echo "=== configure failed; config.log tail ==="
    tail -n 40 config.log 2>/dev/null || true
    exit 1
fi

"${MAKE}" -j "${CVC_JOBS}"
"${MAKE}" install
