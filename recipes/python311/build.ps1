#!/usr/bin/env pwsh
# recipes/python311/build.ps1 — build CPython 3.11 on Windows from source.
#
# CPython's Windows build is self-contained: PCbuild\build.bat -e runs
# get_externals.bat, which fetches CPython's OWN bundled externals (openssl,
# libffi, bzip2, xz, sqlite, zlib, ...) from python's externals repos. So the
# windows build needs NONE of the cvcpkg deps (they are scoped off windows in
# recipe.yaml). PC\layout then produces a complete, deployable install — the same
# python.org-style tree (python.exe + python3XX.dll + Lib/ + DLLs/ + include/ +
# libs/python3XX.lib) that find_package(Python3 Development.Embed) expects.
$ErrorActionPreference = 'Stop'
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $SCRIPT_DIR "../_common/env-windows.ps1")

Set-Location $env:CVC_SOURCE_DIR

# Release x64. -e fetches externals; --no-tkinter (no tcl/tk here). No --pgo: the
# profile-guided build reruns the test suite and is slow + flaky in CI; a plain
# release build is what we ship.
& .\PCbuild\build.bat -e -c Release -p x64 --no-tkinter
if ($LASTEXITCODE -ne 0) { throw "PCbuild\build.bat failed (exit $LASTEXITCODE)" }

# Lay out a full install directly into the install dir. --include-dev carries the
# headers + libs/python311.lib needed to EMBED (volrover3), --include-pip carries
# pip, --precompile bytes-compiles the stdlib.
& .\PCbuild\amd64\python.exe PC\layout `
    --copy $env:CVC_INSTALL_DIR `
    --preset-default `
    --include-dev `
    --include-pip `
    --precompile
if ($LASTEXITCODE -ne 0) { throw "PC\layout failed (exit $LASTEXITCODE)" }
