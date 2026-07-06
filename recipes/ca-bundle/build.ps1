#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $SCRIPT_DIR "../_common/build-vars.ps1")

$CERT_URL = "https://curl.se/ca/cacert-2026-05-14.pem"

$CertDir  = Join-Path $PREFIX "etc/ssl/certs"
$ShareDir = Join-Path $PREFIX "share/ca-bundle"
$CertPath = Join-Path $PREFIX "etc/ssl/cert.pem"

New-Item -ItemType Directory -Force -Path $CertDir, $ShareDir | Out-Null

# Download the CA bundle
Invoke-WebRequest -Uri $CERT_URL -OutFile $CertPath

# Create individual cert symlinks for each CA entry
$n = 0
$inCert = $false
foreach ($line in (Get-Content $CertPath)) {
    if ($line -match '-----BEGIN CERTIFICATE-----') {
        $n++
        $inCert = $true
    }
    if ($inCert -and ($line -match '-----END CERTIFICATE-----')) {
        $link = Join-Path $CertDir "$n.pem"
        if (Test-Path $link) { Remove-Item $link }
        New-Item -ItemType SymbolicLink -Path $link -Target $CertPath | Out-Null
        $inCert = $false
    }
}

# Create convenience env hook
@'
# ca-bundle environment hook -- source this to point OpenSSL at the bundled certs
export SSL_CERT_FILE="{PREFIX}/etc/ssl/cert.pem"
export SSL_CERT_DIR="{PREFIX}/etc/ssl/certs"
'@ -replace '\{PREFIX\}', $PREFIX | Out-File -FilePath (Join-Path $ShareDir "env.sh") -Encoding ascii
