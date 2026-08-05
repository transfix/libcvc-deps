#!/usr/bin/env pwsh
# recipes/ca-bundle/build.ps1 — stage the Mozilla CA bundle into the prefix.
$ErrorActionPreference = 'Stop'

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $SCRIPT_DIR "../_common/env-windows.ps1")

$CERT_URL = "https://curl.se/ca/cacert-2026-05-14.pem"
$CERT_SHA256 = "86a1f3366afac7c6f8ae9f3c779ac221129328c43f0ab2b8817eb2f362a5025c"

$SslDir   = Join-Path $env:CVC_INSTALL_DIR "etc/ssl"
$ShareDir = Join-Path $env:CVC_INSTALL_DIR "share/ca-bundle"
$CertPath = Join-Path $SslDir "cert.pem"

New-Item -ItemType Directory -Force -Path $SslDir, $ShareDir | Out-Null

# Download the CA bundle
Invoke-WebRequest -Uri $CERT_URL -OutFile $CertPath -UseBasicParsing

# Verify SHA-256
$ACTUAL_SHA256 = (Get-FileHash -Path $CertPath -Algorithm SHA256).Hash.ToLower()
if ($ACTUAL_SHA256 -ne $CERT_SHA256) {
    Write-Error "SHA256 mismatch: expected $CERT_SHA256, got $ACTUAL_SHA256"
    exit 1
}

$n = (Select-String -Path $CertPath -Pattern '^-----BEGIN CERTIFICATE-----' -AllMatches).Count

# No etc/ssl/certs/ directory is produced, on purpose -- see the "Usage" note
# in recipe.yaml.  SSL_CERT_DIR resolves certificates only through OpenSSL's
# hashed-directory lookup (<subject-hash>.<seq>), which requires c_rehash and
# therefore an openssl binary at build time; SSL_CERT_FILE covers the use case
# with the single bundle.  This also keeps the recipe free of symlink creation,
# which on Windows needs Developer Mode or an elevated process.

# Convenience env hook.  Single-quoted here-string: nothing is expanded at
# build time.  The hook derives the prefix from its OWN path
# (<prefix>/share/ca-bundle/env.sh) rather than baking in CVC_INSTALL_DIR,
# because the package is unpacked at whatever prefix the consumer chooses.
@'
# ca-bundle environment hook -- source this to point OpenSSL at the bundled certs
# SSL_CERT_DIR is deliberately not set: this package ships only the single-file
# bundle, and an unhashed directory would never be read by OpenSSL anyway.
_ca_bundle_self="${BASH_SOURCE[0]:-$0}"
_ca_bundle_prefix="$(cd "$(dirname "${_ca_bundle_self}")/../.." && pwd)"
export SSL_CERT_FILE="${_ca_bundle_prefix}/etc/ssl/cert.pem"
unset _ca_bundle_self _ca_bundle_prefix
'@ | Out-File -FilePath (Join-Path $ShareDir "env.sh") -Encoding ascii

Write-Host "ca-bundle: staged $n certificates to $SslDir"
