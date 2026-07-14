#!/bin/bash
# Creates a self-signed code-signing identity ("SoundsRight Dev") in the login
# keychain. build-app.sh signs with it when present, giving builds a *stable*
# signing identity: macOS pins TCC grants (Accessibility) to the signer, so
# ad-hoc builds lose the grant on every rebuild while identity-signed builds
# keep it. Run once; may show one or two system password prompts.
set -euo pipefail

IDENTITY="SoundsRight Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    echo "An Apple Development identity is already present — build-app.sh uses it."
    exit 0
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' already present — nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Self-signed certificate with the code-signing EKU, valid 10 years.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

# -legacy: OpenSSL 3 defaults to AES/SHA-256 PKCS12 envelopes, which macOS's
# `security import` cannot parse (fails with "MAC verification failed").
PKCS12_LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
    PKCS12_LEGACY="-legacy"
fi
openssl pkcs12 -export $PKCS12_LEGACY -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:soundsright

# -T pre-authorizes codesign so signing doesn't prompt on every build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P soundsright \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Mark the certificate trusted for code signing (user trust domain).
# This is the step that may show a password prompt.
if ! security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null; then
    echo "warning: couldn't set trust automatically. In Keychain Access → login →"
    echo "Certificates, open '$IDENTITY' → Trust → Code Signing: Always Trust."
fi

# Let Apple tools (codesign) use the imported key without per-use prompts.
# Harmless if it fails — the first build then shows a one-time 'Always Allow'.
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' ready. build-app.sh will use it automatically."
else
    echo "error: identity not usable for code signing yet (trust missing?)." >&2
    exit 1
fi
