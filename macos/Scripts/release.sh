#!/bin/bash
# Build a Release app, zip it, and publish a GitHub release.
# The README download link always fetches Stenojot.zip from the latest release.
#
# Usage: macos/Scripts/release.sh v1.0.0
set -euo pipefail

if [[ $# -ne 1 || "$1" == -* ]]; then
  echo "Usage: macos/Scripts/release.sh <tag>" >&2
  echo "Example: macos/Scripts/release.sh v1.0.0" >&2
  exit 1
fi

TAG="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACOS="$ROOT/macos"
DERIVED="$MACOS/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Stenojot.app"
ZIP="$MACOS/build/Stenojot.zip"

cd "$ROOT"

# Skip Xcode's codesign. The product is copied off this folder (Documents can
# attach Finder info that codesign rejects) and ad-hoc signed below.
xcodebuild \
  -project "$MACOS/Stenojot.xcodeproj" \
  -scheme Stenojot \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

STAGED="$(mktemp -d)/Stenojot.app"
ditto --norsrc "$APP" "$STAGED"
xattr -cr "$STAGED" || true
VERSION="${TAG#v}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGED/Contents/Info.plist"
codesign --force --deep --sign - "$STAGED"
codesign --verify --deep --strict "$STAGED"

rm -f "$ZIP"
ditto -c -k --keepParent "$STAGED" "$ZIP"

gh release create "$TAG" "$ZIP" \
  --title "Stenojot $TAG" \
  --notes "$(cat <<EOF
Apple Silicon, macOS 14 or later.

Unzip and move Stenojot to Applications. The first time you open it, Control-click the app and choose Open, then Open again.

The transcription packages and model weights download on first launch.
EOF
)"

echo "Published $TAG ($ZIP)"
