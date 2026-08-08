#!/bin/bash
#
# Creates the self-signed code signing identity "QuitGuard Local" in the login
# keychain and trusts it for the codeSign policy.
#
# You should only ever need to run this once per machine. The Accessibility
# grant is pinned to this certificate's hash — regenerating it produces a new
# hash and you will have to re-grant Accessibility in System Settings.
#
# Idempotent: exits early if a valid identity already exists.

set -euo pipefail

CERT_NAME="QuitGuard Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Identity \"$CERT_NAME\" already exists and is valid. Nothing to do."
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating self-signed code signing certificate..."
openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy is required: Apple's security(1) cannot read PKCS#12 containers
# written with OpenSSL 3's default (AES/PBKDF2) algorithms and fails with
# "MAC verification failed during PKCS12 import".
echo "==> Packaging as PKCS#12..."
openssl pkcs12 -export -legacy \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/cert.p12" -passout pass:quitguard -name "$CERT_NAME"

echo "==> Importing into login keychain..."
# -A lets codesign use the private key without a per-build authorization prompt.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P quitguard \
    -T /usr/bin/codesign -T /usr/bin/security -A

echo "==> Trusting for code signing..."
# User-domain trust only. No sudo, and nothing is added to the System keychain.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "==> Done:"
security find-identity -v -p codesigning | grep "$CERT_NAME"
