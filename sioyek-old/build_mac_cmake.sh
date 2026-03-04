#!/usr/bin/env bash
set -e

# Compile mupdf
cd mupdf
make -j$(sysctl -n hw.ncpu)
cd ..

# Build sioyek using CMake
mkdir -p build_cmake_mac
cd build_cmake_mac
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu)

# Create App Bundle structure
mkdir -p sioyek.app/Contents/MacOS
mkdir -p sioyek.app/Contents/Resources

cp sioyek sioyek.app/Contents/MacOS/
cp ../resources/Info.plist sioyek.app/Contents/
cp ../pdf_viewer/icon2.ico sioyek.app/Contents/Resources/sioyek.icns # Assuming icon conversion or using ico if supported

# Copy configs and shaders
cp ../pdf_viewer/prefs.config sioyek.app/Contents/MacOS/
cp ../pdf_viewer/prefs_user.config sioyek.app/Contents/MacOS/
cp ../pdf_viewer/keys.config sioyek.app/Contents/MacOS/
cp ../pdf_viewer/keys_user.config sioyek.app/Contents/MacOS/
cp -r ../pdf_viewer/shaders sioyek.app/Contents/MacOS/
cp ../tutorial.pdf sioyek.app/Contents/MacOS/

# Use macdeployqt to package dependencies and create DMG
macdeployqt sioyek.app
codesign --force --deep --sign - sioyek.app
hdiutil create -volname "sioyek" -srcfolder sioyek.app -ov -format UDZO sioyek.dmg

echo "MacOS DMG created in build_cmake_mac/sioyek.dmg"
