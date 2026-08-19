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

# Put the MSVC x64 tool directory on PATH for THIS process before building.
# build.bat drives cl/link through MSBuild's toolset resolution (absolute paths),
# so those compile fine without any PATH setup — but _decimal.vcxproj assembles
# libmpdec\vcdiv64.asm with a raw <CustomBuild> that calls `ml64` (the MASM
# assembler) by BARE NAME, which resolves only off the process PATH. build.bat
# never sources vcvars, and the workflow's step-level PATH accumulation can bury
# or truncate the msvc-dev-cmd entries, so ml64 goes missing and the build dies
# with MSB8066 (exit 9009, "'ml64' is not recognized"). ml64.exe lives in the
# same HostX64\x64 dir as cl/link/lib, so prepending that one directory is a
# deterministic fix with none of the quoting pitfalls of importing all of vcvars.
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    $vswhere = Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe"
}
$vsPath = & $vswhere -latest -products '*' `
    -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' `
    -property installationPath 2>$null | Select-Object -First 1
if (-not $vsPath) { throw "vswhere could not locate a VS install with the x64 VC tools" }
# Newest installed MSVC toolset — the one MSBuild's default v143 toolset resolves
# to (matches what the compilers use), so ml64 stays in lockstep with cl/link.
$ml64 = Get-ChildItem "$vsPath\VC\Tools\MSVC\*\bin\HostX64\x64\ml64.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName | Select-Object -Last 1
if (-not $ml64) { throw "ml64.exe not found under $vsPath\VC\Tools\MSVC" }
Write-Host "Prepending MSVC x64 tools to PATH: $($ml64.DirectoryName)"
$env:PATH = "$($ml64.DirectoryName);$env:PATH"

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
