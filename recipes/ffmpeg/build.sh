#!/usr/bin/env bash
# recipes/ffmpeg/build.sh — build FFmpeg shared libraries on Linux/macOS/BSD.
#
# FFmpeg uses its own hand-written configure (not GNU autotools).  We
# build a lean, self-contained LGPL library set: no CLI programs, no
# docs, only FFmpeg's built-in native codecs (no external x264/x265/…),
# so there are zero external codec dependencies.  This is exactly what
# Qt Multimedia's FFmpeg backend links against.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/../_common/env-${CVC_PLATFORM}.sh"

# Put the cvcpkg prefix bin on PATH so FFmpeg's configure finds nasm
# (built as a build dependency) for x86 assembly optimizations.
export PATH="${CVC_DEPS_PREFIX}/bin:${PATH}"

cd "${CVC_SOURCE_DIR}"

CONFIGURE_ARGS=(
    --prefix="${CVC_INSTALL_DIR}"
    --enable-pic
    --enable-version3
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-static
    --enable-shared
)

if [[ "${CVC_LINK:-shared}" == "static" ]]; then
    CONFIGURE_ARGS=(
        --prefix="${CVC_INSTALL_DIR}"
        --enable-pic
        --enable-version3
        --disable-programs
        --disable-doc
        --disable-debug
        --enable-static
        --disable-shared
    )
fi

# FFmpeg's configure hard-defaults its C compiler to "gcc" and does not
# reliably honour $CC.  On the BSDs (and macOS) the system compiler is
# clang exposed as cc, so pass the platform-selected compiler explicitly.
CONFIGURE_ARGS+=(--cc="${CC:-cc}")
if [[ -n "${CXX:-}" ]]; then
    CONFIGURE_ARGS+=(--cxx="${CXX}")
fi

# On platforms without nasm on PATH, fall back to disabling x86 asm so
# the build still succeeds (nasm is only declared as a build dep on
# linux/BSD; macOS runners ship their own assembler toolchain).
if ! command -v nasm >/dev/null 2>&1; then
    CONFIGURE_ARGS+=(--disable-x86asm)
fi

# Relocatable RPATH so the sibling libav* shared libs resolve within any
# install prefix (the temporary build prefix is cleaned up post-build).
if [[ "${CVC_PLATFORM}" == "macos" ]]; then
    CONFIGURE_ARGS+=(--extra-ldflags="-Wl,-rpath,@loader_path")
else
    CONFIGURE_ARGS+=(--extra-ldflags="-Wl,-rpath,\$ORIGIN")
fi

./configure "${CONFIGURE_ARGS[@]}" || {
    echo "cvcpkg: FFmpeg configure failed — dumping ffbuild/config.log" >&2
    tail -n 80 ffbuild/config.log >&2 || true
    exit 1
}

make -j "${CVC_JOBS}"
make install

# On macOS, FFmpeg stamps each dylib's LC_ID_DYLIB with the absolute
# install path and references siblings by absolute path too.  Rewrite
# both to @rpath so the bundle relocates.
if [[ "${CVC_PLATFORM}" == "macos" ]]; then
    shopt -s nullglob
    _libdir="${CVC_INSTALL_DIR}/lib"
    for dylib in "${_libdir}"/lib*.dylib; do
        [[ -L "${dylib}" ]] && continue
        _base="$(basename "${dylib}")"
        install_name_tool -id "@rpath/${_base}" "${dylib}" || true
        # Repoint references to sibling libav*/libsw* dylibs at @rpath.
        while IFS= read -r dep; do
            case "${dep}" in
                "${_libdir}"/lib*.dylib)
                    install_name_tool -change "${dep}" \
                        "@rpath/$(basename "${dep}")" "${dylib}" || true
                    ;;
            esac
        done < <(otool -L "${dylib}" | awk 'NR>1 {print $1}')
        install_name_tool -add_rpath "@loader_path" "${dylib}" 2>/dev/null || true
    done
    shopt -u nullglob
fi

# Make installed .pc files relocatable.
cvc_rewrite_install_paths
