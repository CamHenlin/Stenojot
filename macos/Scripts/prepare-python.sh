#!/bin/bash
# Download a relocatable CPython 3.12 build for Apple Silicon.
# The app creates its virtualenv from this interpreter on first launch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
PY="$VENDOR/python"
STAMP="$VENDOR/.python-version"
VERSION="cpython-3.12.14+20260901"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260901/${VERSION}-aarch64-apple-darwin-install_only.tar.gz"

if [[ -x "$PY/bin/python3" && "$(cat "$STAMP" 2>/dev/null || true)" == "$VERSION" ]]; then
  exit 0
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $VERSION..."
COPYFILE_DISABLE=1 curl -L --fail --retry 3 -o "$TMP/python.tar.gz" "$URL"
COPYFILE_DISABLE=1 tar -xzf "$TMP/python.tar.gz" -C "$TMP"
rm -rf "$PY"
mv "$TMP/python" "$PY"
xattr -cr "$PY" || true
echo "$VERSION" > "$STAMP"
"$PY/bin/python3" --version
