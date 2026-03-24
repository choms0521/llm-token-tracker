#!/bin/bash
set -euo pipefail

APP_NAME="LLM Token Bar"
BUNDLE_NAME="LLMTokenBar"
DMG_NAME="${BUNDLE_NAME}"
VOLUME_NAME="${APP_NAME}"

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

        # Copy .app from DerivedData
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

# Clean previous artifacts
rm -f "${DMG_OUTPUT}"

# Create staging directory with the .app
STAGING_DIR=$(mktemp -d)
cp -R "$APP_PATH" "${STAGING_DIR}/${APP_NAME}.app"

echo "Creating DMG from: ${APP_PATH}"

create-dmg \
    --volname "${VOLUME_NAME}" \
    --volicon "${ICON_PATH}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 180 200 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 480 200 \
    --no-internet-enable \
    "${DMG_OUTPUT}" \
    "${STAGING_DIR}"

rm -rf "${STAGING_DIR}"

echo ""
echo "DMG created: ${DMG_OUTPUT}"
