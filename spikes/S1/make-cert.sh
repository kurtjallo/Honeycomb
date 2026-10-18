#!/bin/sh
# Creates a free self-signed code-signing certificate, "Honeycomb Spike Signing", in your login keychain.
# macOS asks for your password once, to trust it for code signing.
set -eu
NAME="Honeycomb Spike Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" -out "$DIR/cert.p12" -passout pass:s1
security import "$DIR/cert.p12" -k "$KEYCHAIN" -P s1 -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"
security find-identity -p codesigning | grep "$NAME"
