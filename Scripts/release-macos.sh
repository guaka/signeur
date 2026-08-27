#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

: "${RELEASE_TAG:?Set RELEASE_TAG to the immutable v-prefixed release tag.}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to the Trustroots Foundation Apple team ID.}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to a monotonically increasing integer.}"
: "${MACOS_PROVISIONING_PROFILE_SPECIFIER:?Set MACOS_PROVISIONING_PROFILE_SPECIFIER to the Foundation Developer ID profile name.}"
: "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID.}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID.}"
: "${APP_STORE_CONNECT_KEY_PATH:?Set APP_STORE_CONNECT_KEY_PATH to the private .p8 key file.}"

version="$(Scripts/verify-release-version.sh "$RELEASE_TAG")"
signing_identity="${MACOS_SIGNING_IDENTITY:-Developer ID Application}"
release_root="$repository_root/.release/macos-$version"
archive_path="$release_root/Signstr.xcarchive"
stage_path="$release_root/dmg"
dmg_path="$release_root/Signstr-$version-macOS.dmg"
checksum_path="$dmg_path.sha256"
build_time="$(date -u '+%Y-%d-%m %H:%M UTC')"

if [[ -e "$release_root" ]]; then
  echo "Release output already exists: $release_root" >&2
  exit 1
fi
mkdir -p "$stage_path"

xcodebuild archive \
  -project Signstr.xcodeproj \
  -scheme SignstrMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -skipPackagePluginValidation \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  SIGNSTR_BUILD_TIME="$build_time" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$signing_identity" \
  PROVISIONING_PROFILE_SPECIFIER="$MACOS_PROVISIONING_PROFILE_SPECIFIER" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO

app_path="$archive_path/Products/Applications/Signstr.app"
info_plist="$app_path/Contents/Info.plist"
binary_path="$app_path/Contents/MacOS/Signstr"
entitlements_path="$release_root/entitlements.plist"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"

[[ "$bundle_id" == "org.trustroots.signstr.mac" ]] || { echo "Unexpected bundle identifier: $bundle_id" >&2; exit 1; }
[[ "$bundle_version" == "$version" ]] || { echo "Unexpected app version: $bundle_version" >&2; exit 1; }
[[ "$build_number" == "$BUILD_NUMBER" ]] || { echo "Unexpected build number: $build_number" >&2; exit 1; }

architectures="$(lipo -archs "$binary_path")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
  echo "The release is not universal: $architectures" >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign -d --entitlements :- "$app_path" >"$entitlements_path"
/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$entitlements_path" | grep -F "$APPLE_TEAM_ID.org.trustroots.signstr.mac" >/dev/null
codesign -dvv "$app_path" 2>&1 | grep -F 'flags=0x10000(runtime)' >/dev/null

ditto "$app_path" "$stage_path/Signstr.app"
ln -s /Applications "$stage_path/Applications"
hdiutil create -volname Signstr -srcfolder "$stage_path" -ov -format UDZO "$dmg_path"
codesign --force --timestamp --sign "$signing_identity" "$dmg_path"

xcrun notarytool submit "$dmg_path" \
  --key "$APP_STORE_CONNECT_KEY_PATH" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

(
  cd "$(dirname "$dmg_path")"
  shasum -a 256 "$(basename "$dmg_path")" >"$(basename "$checksum_path")"
)

echo "DMG_PATH=$dmg_path"
echo "CHECKSUM_PATH=$checksum_path"
