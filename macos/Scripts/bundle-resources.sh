#!/bin/bash
# Copy the bundled Python runtime and the transcription sidecar into the app.
set -euo pipefail

"$SRCROOT/Scripts/prepare-python.sh"

RES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$RES/sidecar" "$RES/python"

rsync -a --delete "$SRCROOT/Vendor/python/" "$RES/python/"
cp "$SRCROOT/../sidecar/transcriber.py" "$RES/sidecar/transcriber.py"
cp "$SRCROOT/../sidecar/requirements-app.txt" "$RES/sidecar/requirements-app.txt"
# codesign rejects Finder info and resource forks inside the bundle.
xattr -cr "$RES/python" "$RES/sidecar" || true
