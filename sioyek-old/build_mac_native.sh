#!/usr/bin/env bash
set -e

# Build script for the native macOS version of Sioyek
# This builds a pure Swift application using SwiftUI and PDFKit
# No Qt, MuPDF, or OpenGL dependencies required

echo "=== Building Sioyek (Native macOS Universal) ==="
echo ""

# Save the project root before changing directories
PROJ_ROOT="$(cd "$(dirname "$0")" && pwd)"

cd "$(dirname "$0")/macos-native"

# Clean previous build
rm -rf .build/apple 2>/dev/null || true
rm -rf .build/arm64-apple-macosx 2>/dev/null || true
rm -rf .build/x86_64-apple-macosx 2>/dev/null || true

# Build universal binary (arm64 + x86_64) for release
echo "Building universal binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

# Get the actual binary output path (no-op rebuild, just returns the path)
BIN_PATH=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
echo "Binary path: ${BIN_PATH}"

echo ""
echo "Build complete!"
echo ""

# Create app bundle
APP_NAME="Sioyek"
APP_BUNDLE="build/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

rm -rf build 2>/dev/null || true
mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"

# Copy binary
cp "${BIN_PATH}/Sioyek" "${MACOS}/${APP_NAME}"

# Verify the binary was copied and is not empty
if [ ! -s "${MACOS}/${APP_NAME}" ]; then
    echo "ERROR: Binary is missing or empty!"
    exit 1
fi

echo "Binary size: $(ls -lh "${MACOS}/${APP_NAME}" | awk '{print $5}')"
echo "Binary architectures: $(file "${MACOS}/${APP_NAME}")"

# Copy SPM resource bundle (if it exists)
RESOURCE_BUNDLE=$(find "${BIN_PATH}" -maxdepth 1 -name "*.bundle" 2>/dev/null | head -1)
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "${RESOURCES}/"
    echo "SPM resource bundle copied: $(du -sh "$RESOURCE_BUNDLE" | cut -f1)"
fi

# Copy Info.plist
cp Sources/Sioyek/Resources/Info.plist "${CONTENTS}/Info.plist"

# Copy config files from the main project (if available)
if [ -f "${PROJ_ROOT}/pdf_viewer/prefs.config" ]; then
    cp "${PROJ_ROOT}/pdf_viewer/prefs.config" "${RESOURCES}/prefs.config"
fi
if [ -f "${PROJ_ROOT}/pdf_viewer/prefs_user.config" ]; then
    cp "${PROJ_ROOT}/pdf_viewer/prefs_user.config" "${RESOURCES}/prefs_user.config"
fi
if [ -f "${PROJ_ROOT}/pdf_viewer/keys.config" ]; then
    cp "${PROJ_ROOT}/pdf_viewer/keys.config" "${RESOURCES}/keys.config"
fi
if [ -f "${PROJ_ROOT}/pdf_viewer/keys_user.config" ]; then
    cp "${PROJ_ROOT}/pdf_viewer/keys_user.config" "${RESOURCES}/keys_user.config"
fi
if [ -f "${PROJ_ROOT}/tutorial.pdf" ]; then
    cp "${PROJ_ROOT}/tutorial.pdf" "${RESOURCES}/tutorial.pdf"
fi

# Code sign with hardened runtime (required for Gatekeeper on macOS 10.14.5+)
codesign --force --sign - --options runtime "${APP_BUNDLE}"

echo ""
echo "App bundle created at: ${APP_BUNDLE}"
echo "App bundle size: $(du -sh "${APP_BUNDLE}" | cut -f1)"
echo "App bundle contents:"
find "${APP_BUNDLE}" -type f -exec ls -lh {} \; | awk '{print $5, $9}'

# Optionally create DMG
if command -v hdiutil &>/dev/null; then
    echo ""
    echo "Creating DMG..."
    hdiutil create -volname "Sioyek" -srcfolder "${APP_BUNDLE}" -ov -format UDZO "build/sioyek-native.dmg"
    DMG_SIZE=$(ls -lh "build/sioyek-native.dmg" | awk '{print $5}')
    echo "DMG created at: build/sioyek-native.dmg (size: ${DMG_SIZE})"
fi

echo ""
echo "=== Build Complete ==="
echo "The native macOS app is at: macos-native/${APP_BUNDLE}"
