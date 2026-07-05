#!/usr/bin/env bash
# recipes/nasm/build.sh — build the NASM assembler from source.
#
# NASM is a pure host tool (assembler); it produces no libraries.  We
# build it with its own autotools configure and install just the
# nasm/ndisasm executables into the prefix so downstream recipes
# (FFmpeg) can find it on PATH via $CVC_DEPS_PREFIX/bin.
set -euo pipefail

: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_SOURCE_DIR:?CVC_SOURCE_DIR must be set}"
: "${CVC_JOBS:=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

cd "${CVC_SOURCE_DIR}"

./configure --prefix="${CVC_INSTALL_DIR}"

# `install` copies the nasm/ndisasm executables plus the pre-built man
# pages that ship in the release tarball (no doc toolchain required).
make -j "${CVC_JOBS}"
make install
