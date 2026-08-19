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

# ── Guarantee the MSVC x64 assembler (ml64.exe) for the _decimal build ──────
# _decimal.vcxproj assembles libmpdec\vcdiv64.asm with a raw <CustomBuild> that
# calls `ml64` by BARE NAME. MSBuild builds cl/link via absolute toolset paths
# (so they work regardless of PATH), but that custom-build resolves ml64 only
# off the environment PATH of the cmd MSBuild spawns. build.bat never sources
# vcvars, and env-windows.ps1's Import-CvcMsvcEnv early-returns when cl is
# already present (true on CI via msvc-dev-cmd) — so ml64 was left unguaranteed
# and the build died with MSB8066 (exit 9009, "'ml64' is not recognized").
#
# Source the FULL vcvars64 developer environment into THIS process — the exact
# env a Developer Command Prompt provides, which build.bat -> MSBuild -> the
# custom build all inherit. Uses env-windows.ps1's robust temp-.cmd import
# technique (avoids the fragile inline `cmd /c "..."` quoting).
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { $vswhere = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe' }
$vsRoot = & $vswhere -latest -products '*' `
    -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' `
    -property installationPath 2>$null | Select-Object -First 1
if (-not $vsRoot) { throw 'vswhere found no VS install with the x64 VC tools' }
$vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vsRoot" }
$helper = Join-Path ([System.IO.Path]::GetTempPath()) ("cvc-vcvars-{0}.cmd" -f ([guid]::NewGuid().ToString('N')))
Set-Content -LiteralPath $helper -Value "@echo off`r`ncall `"$vcvars`" >nul 2>&1`r`nset`r`n" -Encoding Ascii
try { $dump = & cmd.exe /c $helper } finally { Remove-Item -LiteralPath $helper -ErrorAction SilentlyContinue }
foreach ($line in $dump) {
    if ($line -match '^([^=]+)=(.*)$') {
        $n = $matches[1]; $v = $matches[2]
        if ($n -in @('_', 'PROMPT')) { continue }
        [Environment]::SetEnvironmentVariable($n, $v, 'Process')
    }
}
# Belt-and-suspenders: also prepend the toolset bin (holds ml64.exe next to cl).
$ml64 = Get-ChildItem "$vsRoot\VC\Tools\MSVC\*\bin\HostX64\x64\ml64.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName | Select-Object -Last 1
if ($ml64) { $env:PATH = "$($ml64.DirectoryName);$env:PATH" }

# Force fresh MSBuild worker nodes that inherit THIS environment (not a reused
# node from an earlier invocation with a stale PATH).
$env:MSBUILDDISABLENODEREUSE = '1'

# ── Diagnostics: prove whether the assembler is resolvable before building ──
# where.exe searches PATH exactly like the cmd MSBuild spawns for the custom
# build, so this tells us if the problem is PATH (fix works) or a sandboxed
# custom-build env (needs a different fix).
Write-Host "DIAG vcvars64:          $vcvars"
Write-Host "DIAG Get-Command ml64:  $((Get-Command ml64.exe -ErrorAction SilentlyContinue).Source)"
Write-Host "DIAG Get-Command cl:    $((Get-Command cl.exe   -ErrorAction SilentlyContinue).Source)"
Write-Host "DIAG where.exe ml64.exe:"
& where.exe ml64.exe 2>&1 | ForEach-Object { Write-Host "     $_" }
Write-Host "DIAG ml64.exe locations under the toolset (which host bins have it?):"
Get-ChildItem "$vsRoot\VC\Tools\MSVC\*\bin\Host*\x64\ml64.exe" -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "     $($_.FullName)" }
Write-Host "DIAG PATH length: $($env:PATH.Length)"

# Prefer the x64-hosted toolset the SUPPORTED way (env var — MSBuild reads it).
# A raw /p:PreferredToolArchitecture=x64 arg does NOT survive build.bat's arg
# parsing: it mangles the MSBuild command line into MSB1008 "Only one project can
# be specified". Harmless if it isn't the deciding factor.
$env:PreferredToolArchitecture = 'x64'

# Run build.bat inside a cmd that sourced vcvars64 in the SAME process — the
# canonical Developer Command Prompt scenario CPython's Windows build is designed
# for. _decimal's vcdiv64.asm custom-build invokes `ml64` by bare name; MSBuild
# builds cl/link via absolute toolset paths, but that custom-build resolves ml64
# off the shell env. Sourcing vcvars directly in the cmd that launches build.bat
# gives MSBuild (and its custom-build) the assembler env first-hand, rather than
# relying on pwsh -> build.bat env propagation (which left ml64 resolvable in
# pwsh yet still invisible to the custom-build). Build the .cmd with explicit
# CRLF (matches env-windows.ps1; LF-only .cmd files misparse `call`/`if`).
$src = $env:CVC_SOURCE_DIR
$buildBat = Join-Path ([System.IO.Path]::GetTempPath()) ("cvc-pybuild-{0}.cmd" -f ([guid]::NewGuid().ToString('N')))
$batLines = @(
    '@echo off',
    "call `"$vcvars`"",
    'if errorlevel 1 exit /b 1',
    'echo DIAG-cmd where ml64.exe:',
    'where ml64.exe',
    "cd /d `"$src`"",
    'call .\PCbuild\build.bat -e -c Release -p x64 --no-tkinter',
    'exit /b %errorlevel%'
)
Set-Content -LiteralPath $buildBat -Value ($batLines -join "`r`n") -Encoding Ascii
try { & cmd.exe /c $buildBat } finally { Remove-Item -LiteralPath $buildBat -ErrorAction SilentlyContinue }
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
