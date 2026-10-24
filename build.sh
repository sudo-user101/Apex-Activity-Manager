#!/bin/bash
# Builds "Apex Activity Manager.app" (native SwiftUI) into ./dist.
#   ./build.sh               release build for this Mac's architecture
#   ./build.sh --universal   Apple Silicon + Intel in one binary
#   ./build.sh --dmg         also create a .dmg
# Build products go to a temp directory so cloud-synced folders stay clean;
# override with BUILD_DIR=/path ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0; DMG=0
for a in "$@"; do
  case "$a" in
    --universal) UNIVERSAL=1 ;;
    --dmg) DMG=1 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

BUILD_DIR="${BUILD_DIR:-${TMPDIR:-/tmp}/taskmanager-native-build}"
ARCH_ARGS=()
[ "$UNIVERSAL" = 1 ] && ARCH_ARGS=(--arch arm64 --arch x86_64)

swift build -c release --scratch-path "$BUILD_DIR" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

APP="dist/Apex Activity Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TaskManager" "$APP/Contents/MacOS/TaskManager"
cp "$BIN_DIR/ApexFanHelper" "$APP/Contents/MacOS/apex-fanhelper"   # privileged fan helper (installed on demand)
strip -x "$APP/Contents/MacOS/apex-fanhelper" 2>/dev/null || true
strip -x "$APP/Contents/MacOS/TaskManager" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign the nested helper first (strip removes the linker's signature on universal builds).
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/apex-fanhelper" >/dev/null
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$DMG" = 1 ]; then
  # Installer disk image: the app next to an Applications shortcut, so
  # installing is one drag. Staged outside the synced folder.
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  DMG_PATH="dist/Apex Activity Manager ${VERSION}.dmg"
  STAGE="$BUILD_DIR/dmg-stage"
  rm -rf "$STAGE" "$DMG_PATH"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
  hdiutil create -volname "Apex Activity Manager" -srcfolder "$STAGE" -ov -format UDRW "$BUILD_DIR/apex-rw.dmg" >/dev/null
  # Show the volume icon (custom-icon flag on the volume root).
  MNT="$(hdiutil attach -nobrowse -noverify "$BUILD_DIR/apex-rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')"
  SetFile -a C "$MNT" 2>/dev/null || true
  hdiutil detach "$MNT" -force >/dev/null
  hdiutil convert "$BUILD_DIR/apex-rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
  rm -rf "$STAGE" "$BUILD_DIR/apex-rw.dmg"
  echo "Built $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
fi
