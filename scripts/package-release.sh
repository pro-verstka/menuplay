#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <path-to-app> <output-dir>" >&2
    exit 1
fi

SOURCE_APP="${1%/}"
OUTPUT_DIR="${2%/}"

if [ ! -d "$SOURCE_APP" ]; then
    echo "App bundle not found: $SOURCE_APP" >&2
    exit 1
fi

APP_BUNDLE="$(basename "$SOURCE_APP")"
APP_NAME="${APP_BUNDLE%.app}"
ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-macos.zip"
DMG_PATH="$OUTPUT_DIR/${APP_NAME}-macos.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-release.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH"

ditto "$SOURCE_APP" "$STAGING_DIR/$APP_BUNDLE"
ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/$APP_BUNDLE" "$ZIP_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Created release assets:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
