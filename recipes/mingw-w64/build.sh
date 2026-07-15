#!/usr/bin/env bash
# recipes/mingw-w64/build.sh — stage the prebuilt llvm-mingw cross-toolchain.
#
# llvm-mingw is a prebuilt, relocatable Linux→Windows cross-toolchain: clang,
# lld, the mingw-w64 CRT + headers, and the x86_64-w64-mingw32-* wrappers all
# resolve their resources relative to bin/, so a plain copy into the prefix
# works.  No compilation happens here.
set -euo pipefail

: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_SOURCE_DIR:?CVC_SOURCE_DIR must be set}"

mkdir -p "${CVC_INSTALL_DIR}"
cp -a "${CVC_SOURCE_DIR}/." "${CVC_INSTALL_DIR}/"

# Sanity check: the x86_64 Windows cross-compiler must be present and runnable.
"${CVC_INSTALL_DIR}/bin/x86_64-w64-mingw32-clang" --version >/dev/null
echo "mingw-w64 (llvm-mingw) staged to ${CVC_INSTALL_DIR}"
