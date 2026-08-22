#!/usr/bin/env bash
# recipes/curl/build.sh — build libcurl from source using autotools.
# Uses autotools (./configure) so cmake is NOT required — this allows
# curl to be built before cmake, breaking the circular dependency.
set -euo pipefail

: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_SOURCE_DIR:?CVC_SOURCE_DIR must be set}"
: "${CVC_DEPS_PREFIX:=}"
: "${CVC_JOBS:=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

cd "${CVC_SOURCE_DIR}"

CONFIGURE_ARGS=(
    --prefix="${CVC_INSTALL_DIR}"
    --with-openssl
    --with-zlib                 # system zlib (can't use our recipe — circular dep)
    --without-libpsl
    --without-brotli
    --without-zstd              # our zstd recipe depends on cmake (circular)
    --without-nghttp2
    --without-libidn2
    --without-libssh2
    --disable-ldap
    --disable-manual
    --disable-dict
    --disable-gopher
    --disable-imap
    --disable-mqtt
    --disable-pop3
    --disable-rtsp
    --disable-smb
    --disable-smtp
    --disable-telnet
    --disable-tftp
)

# Respect static/shared link mode.
if [[ "${CVC_LINK:-shared}" == "static" ]]; then
    CONFIGURE_ARGS+=(--disable-shared --enable-static)
else
    CONFIGURE_ARGS+=(--enable-shared --disable-static)
fi

# Point to our openssl if built as a dependency.
if [[ -n "${CVC_DEPS_PREFIX}" && -d "${CVC_DEPS_PREFIX}/include/openssl" ]]; then
    CONFIGURE_ARGS+=(--with-openssl="${CVC_DEPS_PREFIX}")
    export PKG_CONFIG_PATH="${CVC_DEPS_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    export LD_LIBRARY_PATH="${CVC_DEPS_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    # Embed $ORIGIN RPATH so libcurl finds libssl next to itself in any prefix.
    # The temporary build prefix gets cleaned up, so absolute RPATHs won't work.
    #
    # Needs a DOUBLED dollar sign, not a single backslash-escaped one: the
    # single `\$ORIGIN` this used to be produces a literal one-`$` string from
    # bash, but that string is then substituted again by make (LDFLAGS flows
    # through the generated Makefile), and make's own `$X` syntax treats `$O`
    # as a reference to a single-letter variable named "O" (undefined, so
    # empty) — silently eating the "$O" and leaving `RIGIN` baked into the
    # actual RPATH (confirmed via readelf -d on a built libcurl.so: `Library
    # runpath: [RIGIN]`). `\$\$ORIGIN` survives both layers: bash removes the
    # backslashes leaving literal `$$ORIGIN`, then make's own `$$` -> `$`
    # collapse leaves exactly `$ORIGIN` for the linker.
    export LDFLAGS="${LDFLAGS:-} -Wl,-rpath,\$\$ORIGIN"
    # On BSDs, dlopen() lives in libc (no separate -ldl).  Static OpenSSL
    # requires -lpthread at link time, but curl's configure probes only add
    # -lpthread via the "-ldl -lpthread" code path, which never fires on BSD.
    # Pass -lpthread as a configure variable so the HMAC link tests succeed.
    case "$(uname)" in
        *BSD) CONFIGURE_ARGS+=(LIBS="-lpthread") ;;
    esac
fi

./configure "${CONFIGURE_ARGS[@]}"
# Serial build: under -j>1, curl's lib/Makefile builds the sibling libtool
# targets libcurl.la (installed, shared) and libcurlu.la (noinst
# convenience lib, same sources under different .lo names) close together,
# and a parallel run can interleave their CCLD/.libs steps — observed as
# "ld: cannot find libcurl.so.4" / "unknown directive" in libcurl.exp
# immediately after "CCLD libcurlu.la", with make reporting "Waiting for
# unfinished jobs". This hit linux, freebsd, openbsd, and netbsd
# simultaneously in the same build run — a libtool/make race, not a
# platform-specific bug. curl is small enough that a serial build's extra
# time is a fair price for not chasing this race across every platform.
make -j1
make install

# OpenBSD: libtool's shared-library versioning support does not emit a
# DT_SONAME for libcurl.so at all (confirmed via readelf -d on a built
# libcurl.so.12.0 — no SONAME tag, vs. e.g. libssl.so.3/libcrypto.so.3 from
# our own openssl recipe, which DO have one). Per ELF semantics, a consumer
# linking against a .so with no self-declared SONAME falls back to recording
# the literal path it resolved the library at — which is THIS job's own
# ephemeral CVC_DEPS_PREFIX. Every later consumer of a packaged libcurl then
# bakes in that dead path (cmake: "ld.so: cmake: can't load library '.../
# cvcpkg-job-curl-.../lib/libcurl.so.12.0'"), independent of the consumer's
# own RPATH/LD_LIBRARY_PATH handling — a NEEDED entry containing '/' is
# opened as a literal path, never searched.
#
# Tried forcing it at curl's own link time via LDFLAGS -Wl,-soname,X — both a
# single comma-joined flag and two separate -Wl, flags reliably broke the
# build instead ("ld: error: cannot open libcurl.so.12.0: No such file or
# directory"): libtool's own argument classifier matches the filename-shaped
# value as a reference to an existing library to link against and strips the
# -Wl, protection, regardless of how the flag is split. Post-processing the
# ALREADY-LINKED artifact with patchelf sidesteps libtool's argument handling
# entirely.
if [[ "${CVC_PLATFORM:-}" == "openbsd" ]]; then
    _cvc_libcurl_versioned=$(ls "${CVC_INSTALL_DIR}"/lib/libcurl.so.* 2>/dev/null | head -1 || true)
    if [[ -n "${_cvc_libcurl_versioned}" ]]; then
        _cvc_libcurl_name="$(basename "${_cvc_libcurl_versioned}")"
        patchelf --set-soname "${_cvc_libcurl_name}" "${_cvc_libcurl_versioned}"
        # libtool also never creates the bare libcurl.so symlink (only the
        # versioned file lands in the install dir), which is what a plain
        # -lcurl link line conventionally expects to find.
        if [[ ! -e "${CVC_INSTALL_DIR}/lib/libcurl.so" ]]; then
            ln -sf "${_cvc_libcurl_name}" "${CVC_INSTALL_DIR}/lib/libcurl.so"
        fi
    fi
fi
