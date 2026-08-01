#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---build-only}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DIR="$ROOT_DIR/build-release-current"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_PATH="$DERIVED_DIR/Build/Products/Release/Snag.app"
VERSION="1.0"
DMG_PATH="$OUTPUT_DIR/Snag-$VERSION.dmg"
ZIP_PATH="$OUTPUT_DIR/Snag-$VERSION.zip"
IDENTITY="${SNAG_SIGNING_IDENTITY:-Developer ID Application: Armando Costa (5HT736L2AJ)}"
NOTARY_PROFILE="${SNAG_NOTARY_PROFILE:-SnagNotary}"
TIMESTAMP_OPTION="--timestamp=none"
if [[ "$MODE" == "--notarize" || "$MODE" == "notarize" ]]; then
  TIMESTAMP_OPTION="--timestamp"
fi

mkdir -p "$OUTPUT_DIR"

xcodebuild \
  -project "$ROOT_DIR/Snag.xcodeproj" \
  -scheme Snag \
  -configuration Release \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

while IFS= read -r candidate; do
  if /usr/bin/file "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign --force --options runtime "$TIMESTAMP_OPTION" --sign "$IDENTITY" "$candidate"
  fi
done < <(/usr/bin/find "$APP_PATH/Contents/Resources/bin" -type f -print)

/usr/bin/codesign --force --options runtime "$TIMESTAMP_OPTION" \
  --entitlements "$ROOT_DIR/Sources/Snag.entitlements" \
  --sign "$IDENTITY" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$MODE" == "--build-only" || "$MODE" == "build" ]]; then
  echo "Signed release ready: $APP_PATH"
  exit 0
fi

if [[ "$MODE" != "--notarize" && "$MODE" != "notarize" ]]; then
  echo "usage: $0 [--build-only|--notarize]" >&2
  exit 2
fi

/bin/rm -f "$ZIP_PATH" "$DMG_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
/usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$APP_PATH"

/usr/bin/hdiutil create -volname Snag -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
/usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
/usr/bin/xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$DMG_PATH"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "Notarized release ready: $DMG_PATH"
