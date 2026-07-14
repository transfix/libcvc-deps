# recipes/openssh-win/build.ps1 — build the Win32-OpenSSH port from source with
# MSVC, linking cvcpkg's own OpenSSL + zlib (from CVC_DEPS_PREFIX) instead of the
# vcpkg-fetched crypto the upstream build normally uses.
#
# MSVC (cl.exe / msbuild) is put on PATH by the builder's env-windows helper.
# EXPERIMENTAL: the upstream solution is tightly coupled to its vcpkg crypto
# layout — expect to iterate the lib-name/search-path wiring on a real builder.
$ErrorActionPreference = 'Stop'

if (-not $env:CVC_SOURCE_DIR) { throw 'CVC_SOURCE_DIR must be set' }
if (-not $env:CVC_INSTALL_DIR) { throw 'CVC_INSTALL_DIR must be set' }
if (-not $env:CVC_DEPS_PREFIX) { throw 'CVC_DEPS_PREFIX must be set (openssl+zlib deps)' }

$src = $env:CVC_SOURCE_DIR
$dst = $env:CVC_INSTALL_DIR
$deps = $env:CVC_DEPS_PREFIX
$winDir = Join-Path $src 'contrib\win32\openssh'
$sln = Join-Path $winDir 'Win32-OpenSSH.sln'
if (-not (Test-Path $sln)) { throw "solution not found: $sln" }

# 1. Stage our OpenSSL + zlib where the solution's paths.targets expects them:
#    it links `libcrypto.lib` (SSLLib) and `zs.lib` (release zlib) and searches
#    the solution's lib\ dir.  Copy our import libs under those names, and make
#    our headers/libs visible to cl.exe / link.exe via INCLUDE / LIB.
$libDir = Join-Path $winDir 'lib\x64'
New-Item -ItemType Directory -Force -Path $libDir | Out-Null

$crypto = Get-ChildItem "$deps\lib\libcrypto*.lib" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $crypto) { throw "cvcpkg openssl import lib not found under $deps\lib (libcrypto*.lib)" }
Copy-Item $crypto.FullName (Join-Path $libDir 'libcrypto.lib') -Force

$zlib = Get-ChildItem "$deps\lib\zlib*.lib", "$deps\lib\zs*.lib", "$deps\lib\z.lib" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $zlib) { throw "cvcpkg zlib import lib not found under $deps\lib" }
Copy-Item $zlib.FullName (Join-Path $libDir 'zs.lib') -Force

$env:INCLUDE = "$deps\include;$env:INCLUDE"
$env:LIB = "$libDir;$deps\lib;$env:LIB"

# 2. Build the solution (Release/x64).  Point the SSL/zlib lib+include dirs at
#    our staged copies and force UseOpenSSL so the crypto paths are compiled in.
$jobs = if ($env:CVC_JOBS) { $env:CVC_JOBS } else { [Environment]::ProcessorCount }
& msbuild $sln `
    /p:Configuration=Release `
    /p:Platform=x64 `
    /p:UseOpenSSL=true `
    "/p:OpenSSL-Lib-Path=$libDir" `
    "/p:OpenSSL-Include-Path=$deps\include" `
    /m:$jobs /nologo /verbosity:minimal
if ($LASTEXITCODE -ne 0) { throw "msbuild failed with exit code $LASTEXITCODE" }

# 3. Stage the built binaries + our libcrypto runtime + sample config.
$bin = Join-Path $src 'bin\x64\Release'
if (-not (Test-Path $bin)) { $bin = Join-Path $src 'bin\x64' }  # layout fallback
New-Item -ItemType Directory -Force -Path "$dst\bin", "$dst\etc\ssh" | Out-Null
Copy-Item "$bin\*.exe" "$dst\bin\" -Force
Copy-Item "$deps\bin\libcrypto*.dll" "$dst\bin\" -Force -ErrorAction SilentlyContinue
$sample = Join-Path $winDir 'sshd_config_default'
if (Test-Path $sample) {
    Copy-Item $sample "$dst\etc\ssh\sshd_config.sample" -Force
}

Write-Host "Win32-OpenSSH built from source and staged to $dst"
