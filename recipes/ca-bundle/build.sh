#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../_common/build-vars.sh"

CERT_URL="https://curl.se/ca/cacert-2026-05-14.pem"

mkdir -p "${PREFIX}/etc/ssl/certs" "${PREFIX}/share/ca-bundle"

# Download the CA bundle
curl -fsSL "${CERT_URL}" -o "${PREFIX}/etc/ssl/cert.pem"

# Create individual cert symlinks for each CA entry
cd "${PREFIX}/etc/ssl"
# Split the PEM into individual certs and create symlinks
awk '
    /-----BEGIN CERTIFICATE-----/ { n++ }
    n && /-----END CERTIFICATE-----/ {
        fname = "certs/" n ".pem"
        system("ln -sf ../cert.pem " fname)
    }
' cert.pem

# Create convenience env hook
cat > "${PREFIX}/share/ca-bundle/env.sh" << EOF
# ca-bundle environment hook -- source this to point OpenSSL at the bundled certs
export SSL_CERT_FILE="${PREFIX}/etc/ssl/cert.pem"
export SSL_CERT_DIR="${PREFIX}/etc/ssl/certs"
EOF
