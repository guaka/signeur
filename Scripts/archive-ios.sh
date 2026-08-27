#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to the Trustroots Foundation Apple team ID.}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to an unused, monotonically increasing integer.}"

archive_path="${ARCHIVE_PATH:-$repository_root/.release/Signstr-iOS.xcarchive}"
build_time="$(date -u '+%Y-%d-%m %H:%M UTC')"
mkdir -p "$(dirname "$archive_path")"

xcodebuild archive \
  -project Signstr.xcodeproj \
  -scheme Signstr \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  SIGNSTR_BUILD_TIME="$build_time"

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$archive_path/Info.plist")"
if [[ "$actual_bundle_id" != "org.trustroots.signstr" ]]; then
  echo "Unexpected archived bundle identifier: $actual_bundle_id" >&2
  exit 1
fi

echo "Created $archive_path"
echo "Upload this archive with Xcode Organizer after completing export compliance in App Store Connect."
