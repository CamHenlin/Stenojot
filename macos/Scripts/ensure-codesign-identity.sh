#!/bin/bash
# Keep a stable local signing identity so Screen Recording permission survives rebuilds.
# Ad-hoc signatures ("-") change cdhash every build, and macOS then treats the app as a new binary.
set -euo pipefail

IDENTITY="ParakeetTranscriberDev"
KEYCHAIN="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/.codesign/codesign.keychain-db"
PASSWORD="parakeet-local-codesign"

mkdir -p "$(dirname "$KEYCHAIN")"

# A leftover certificate with no usable private key still has to be recreated.
if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENTITY\""; then
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cat > "$work/cert.cfg" << EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ${IDENTITY}
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -new -newkey rsa:2048 -x509 -days 3650 -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/cert.cfg" >/dev/null 2>&1
  # SHA1 PBE is what the macOS security tool can import. OpenSSL 3's default MAC fails.
  openssl pkcs12 -export \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/cert.p12" -passout pass:"$PASSWORD" -name "$IDENTITY" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
  security import "$work/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
  rm -rf "$work"
  trap - EXIT
fi

security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

paths=()
found=0
while IFS= read -r item; do
  [[ -z "$item" ]] && continue
  paths+=("$item")
  if [[ "$item" == "$KEYCHAIN" ]]; then
    found=1
  fi
done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')

if [[ "$found" -eq 0 ]]; then
  security list-keychains -d user -s "$KEYCHAIN" "${paths[@]}"
fi
