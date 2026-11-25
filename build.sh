#!/bin/zsh
# Builds "Ant AI Launcher.app" with the Command Line Tools (no Xcode project needed).
#   ./build.sh            universal build into ./build, signed ad hoc
#   ./build.sh install    build, then copy to ~/Applications and open it
#
# Release builds (Developer ID signing + notarization) use ./release.sh, which calls this first.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Ant AI Launcher"
EXECUTABLE="AntAILauncher"
BUNDLE_ID="ai.antcodelabs.ant-ai-launcher"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="build/${APP_NAME}.app"
ENTITLEMENTS="Resources/AntAILauncher.entitlements"

rm -rf "$OUT" build/arch
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" build/arch

# Universal binary: Apple silicon + Intel, macOS 14 or later.
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "${ARCH}-apple-macos14.0" \
    -file-prefix-map "$PWD=." \
    -o "build/arch/${EXECUTABLE}-${ARCH}" \
    Sources/*.swift
done
lipo -create -output "$OUT/Contents/MacOS/${EXECUTABLE}" build/arch/${EXECUTABLE}-*

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 AntCodeLabs Limited · antcodelabs.ai</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Ant AI Launcher sends Claude the folder or session to open, and brings Terminal tabs to the front.</string>
</dict>
</plist>
PLIST

# App icon, drawn by the app's own Brand code (the ant from antcodelabs.ai).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$OUT/Contents/MacOS/${EXECUTABLE}" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

# Ad hoc signature with the same hardened runtime and entitlements as a release build.
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$OUT" >/dev/null
echo "Built $OUT (v${VERSION}, build ${BUILD_NUMBER}, $(lipo -archs "$OUT/Contents/MacOS/${EXECUTABLE}"))"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/${APP_NAME}.app"
  mkdir -p "$HOME/Applications"
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  for _ in {1..50}; do pgrep -x "$EXECUTABLE" >/dev/null || break; sleep 0.1; done  # let it exit before relaunching
  rm -rf "$DEST"
  cp -R "$OUT" "$DEST"
  open "$DEST"
  echo "Installed to $DEST"
fi
