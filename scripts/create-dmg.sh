#!/bin/bash
set -euo pipefail

APP_NAME="LLM Token Bar"
BUNDLE_NAME="LLMTokenBar"
DMG_NAME="${BUNDLE_NAME}"
VOLUME_NAME="${APP_NAME}"

# Release signing/notarization defaults (override via env when needed)
DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-Developer ID Application: minseok cho (9ADWM2H336)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DMG_OUTPUT="${PROJECT_DIR}/${DMG_NAME}.dmg"
ICON_PATH="${PROJECT_DIR}/LLMTokenBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"

# Accept .app path as argument, or build from source
if [ $# -ge 1 ]; then
    APP_PATH="$1"
else
    BUILD_DIR="${PROJECT_DIR}/.build-release"
    APP_PATH="${BUILD_DIR}/${BUNDLE_NAME}.app"

    if [ ! -d "$APP_PATH" ]; then
        echo "Building Release..."
        cd "$PROJECT_DIR"
        xcodegen generate
        xcodebuild -project "${BUNDLE_NAME}.xcodeproj" \
            -scheme "${BUNDLE_NAME}" \
            -configuration Release \
            -derivedDataPath "${BUILD_DIR}" \
            -arch arm64 \
            build

        APP_PRODUCT=$(find "${BUILD_DIR}" -name "${BUNDLE_NAME}.app" -o -name "${APP_NAME}.app" | head -1)
        if [ -z "$APP_PRODUCT" ]; then
            echo "Error: .app not found in build output"
            exit 1
        fi
        if [ "$APP_PRODUCT" != "$APP_PATH" ]; then
            cp -R "$APP_PRODUCT" "$APP_PATH"
        fi
    fi
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at ${APP_PATH}"
    echo "Usage: $0 [path/to/App.app]"
    exit 1
fi

# Always re-sign app with Developer ID + hardened runtime for release
/usr/bin/codesign --force --deep --options runtime --timestamp \
  --sign "${DEVELOPER_ID_APP}" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Clean previous artifact
rm -f "${DMG_OUTPUT}"

# Create staging directory with fixed display name
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "${STAGING_DIR}"' EXIT
cp -R "$APP_PATH" "${STAGING_DIR}/${APP_NAME}.app"

echo "Creating installer-style DMG from: ${APP_PATH}"

# Preferred: create-dmg (Finder-styled). If Finder AppleScript times out, fallback to appdmg.
set +e
create-dmg \
    --volname "${VOLUME_NAME}" \
    --volicon "${ICON_PATH}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 180 200 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 480 200 \
    --hdiutil-retries 10 \
    --no-internet-enable \
    "${DMG_OUTPUT}" \
    "${STAGING_DIR}"
CREATE_DMG_RC=$?
set -e

if [ $CREATE_DMG_RC -ne 0 ]; then
  echo "create-dmg failed (likely Finder AppleScript timeout). Falling back to appdmg..."
  TMP_SPEC="${STAGING_DIR}/appdmg.json"
  cat > "$TMP_SPEC" <<JSON
{
  "title": "${VOLUME_NAME}",
  "format": "UDZO",
  "window": { "size": { "width": 660, "height": 400 } },
  "icon-size": 128,
  "contents": [
    { "x": 180, "y": 200, "type": "file", "path": "${STAGING_DIR}/${APP_NAME}.app" },
    { "x": 480, "y": 200, "type": "link", "path": "/Applications" }
  ]
}
JSON
  PATH="/usr/sbin:$PATH" npx -y appdmg "$TMP_SPEC" "${DMG_OUTPUT}"
fi

# Sign + notarize + staple DMG
/usr/bin/codesign --force --timestamp --sign "${DEVELOPER_ID_APP}" "${DMG_OUTPUT}"
xcrun notarytool submit "${DMG_OUTPUT}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG_OUTPUT}"
xcrun stapler validate "${DMG_OUTPUT}"

echo ""
echo "DMG created (installer-style, signed+notarized): ${DMG_OUTPUT}"
