#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/package-macos.sh [options]

Build and package the macOS app.

Options:
  --skip-build   Reuse the existing SwiftPM release build.
  --app-only     Only assemble and sign .build/package/内存守卫.app.
  --no-zip       Do not create dist/MemoryGuardian-macOS.zip.
  --no-dmg       Do not create dist/内存守卫-macOS.dmg.
  --no-verify    Skip package verification checks.
  -h, --help     Show this help.

Environment overrides:
  APP_NAME             Default: 内存守卫
  BUNDLE_IDENTIFIER    Default: com.guuguo.MemoryGuardian
  VERSION              Default: 1.0.0
  BUILD_NUMBER         Default: 1
  SIGN_IDENTITY        Default: - (ad-hoc signing)
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-内存守卫}"
EXECUTABLE_NAME="MemoryGuardian"
PACKAGE_NAME="MemoryGuardian"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.guuguo.MemoryGuardian}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

DO_BUILD=1
DO_ZIP=1
DO_DMG=1
DO_VERIFY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      DO_BUILD=0
      ;;
    --app-only)
      DO_ZIP=0
      DO_DMG=0
      ;;
    --no-zip)
      DO_ZIP=0
      ;;
    --no-dmg)
      DO_DMG=0
      ;;
    --no-verify)
      DO_VERIFY=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

absolute_path() {
  local target="$1"
  local dir
  local base
  dir="$(cd "$(dirname "$target")" && pwd)"
  base="$(basename "$target")"
  printf '%s/%s\n' "$dir" "$base"
}

require_tool swift
require_tool sips
require_tool iconutil
require_tool codesign
require_tool zip
require_tool unzip
require_tool hdiutil

if [[ $DO_BUILD -eq 1 ]]; then
  swift build -c release
fi

BUILD_DIR="$(swift build -c release --show-bin-path | tail -n 1)"
EXECUTABLE_PATH="${BUILD_DIR}/${EXECUTABLE_NAME}"
RESOURCE_BUNDLE_PATH="${BUILD_DIR}/${PACKAGE_NAME}_${PACKAGE_NAME}.bundle"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Missing executable: $EXECUTABLE_PATH" >&2
  echo "Run without --skip-build first." >&2
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
  echo "Missing resource bundle: $RESOURCE_BUNDLE_PATH" >&2
  echo "Run without --skip-build first." >&2
  exit 1
fi

PACKAGE_DIR=".build/package"
APP_DIR="${PACKAGE_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICON_SOURCE="Sources/MemoryGuardian/Resources/AppIcon/memory-guardian-icon.png"
ICONSET_DIR="${PACKAGE_DIR}/AppIcon.iconset"
ICON_PATH="${RESOURCES_DIR}/AppIcon.icns"
DIST_DIR="dist"
ZIP_PATH="${DIST_DIR}/MemoryGuardian-macOS.zip"
DMG_PATH="${DIST_DIR}/${APP_NAME}-macOS.dmg"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing icon source: $ICON_SOURCE" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR" "$DIST_DIR"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

cp "$EXECUTABLE_PATH" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"
cp -R "$RESOURCE_BUNDLE_PATH" "$RESOURCES_DIR/"
cp "$ICON_SOURCE" "${RESOURCES_DIR}/memory-guardian-icon.png"

sips -z 16 16 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$ICON_PATH"

xattr -cr "$APP_DIR"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

if [[ $DO_ZIP -eq 1 ]]; then
  rm -f "$ZIP_PATH"
  (cd "$PACKAGE_DIR" && zip -qry -X "$ROOT_DIR/$ZIP_PATH" "${APP_NAME}.app")
fi

if [[ $DO_DMG -eq 1 ]]; then
  rm -f "$DMG_PATH"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"
fi

if [[ $DO_VERIFY -eq 1 ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"

  if [[ $DO_ZIP -eq 1 ]]; then
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    unzip -q "$ZIP_PATH" -d "$TMP_DIR"
    codesign --verify --deep --strict --verbose=2 "$TMP_DIR/${APP_NAME}.app"
  fi

  if [[ $DO_DMG -eq 1 ]]; then
    hdiutil verify "$DMG_PATH"
  fi
fi

echo
echo "Package complete:"
echo "  app: $(absolute_path "$APP_DIR")"
if [[ $DO_ZIP -eq 1 ]]; then
  echo "  zip: $(absolute_path "$ZIP_PATH")"
fi
if [[ $DO_DMG -eq 1 ]]; then
  echo "  dmg: $(absolute_path "$DMG_PATH")"
fi
