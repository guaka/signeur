#!/usr/bin/env bash

set -euo pipefail

readonly platform="${1:-all}"
readonly repository_root="$(git rev-parse --show-toplevel)"

run_ios() {
    local destination_id="${SIGNSTR_IOS_DESTINATION_ID:-}"
    if [[ -z "${destination_id}" ]]; then
        destination_id="$(xcrun simctl list devices available | sed -nE '/iPhone/ s/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\).*/\1/p' | head -n 1)"
    fi
    if [[ -z "${destination_id}" ]]; then
        echo "No available iPhone simulator was found." >&2
        exit 1
    fi
    xcrun simctl boot "${destination_id}" 2>/dev/null || true
    xcrun simctl bootstatus "${destination_id}" -b
    xcodebuild \
        -project "${repository_root}/Signstr.xcodeproj" \
        -scheme Signstr \
        -destination "platform=iOS Simulator,id=${destination_id}" \
        -parallel-testing-enabled NO \
        -skipPackagePluginValidation \
        -only-testing:SignstrE2ETests \
        test
}

run_macos() {
    xcodebuild \
        -project "${repository_root}/Signstr.xcodeproj" \
        -scheme SignstrMac \
        -destination 'platform=macOS' \
        -skipPackagePluginValidation \
        -only-testing:SignstrMacE2ETests \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        DEVELOPMENT_TEAM= \
        CODE_SIGN_ENTITLEMENTS= \
        test
}

case "${platform}" in
    ios) run_ios ;;
    macos) run_macos ;;
    all) run_ios; run_macos ;;
    *) echo "Usage: $0 [ios|macos|all]" >&2; exit 64 ;;
esac
