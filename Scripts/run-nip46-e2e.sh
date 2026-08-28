#!/usr/bin/env bash

set -euo pipefail

readonly platform="${1:-all}"
readonly repository_root="$(git rev-parse --show-toplevel)"

run_ios() {
    local destination_id="${SIGNSTR_IOS_DESTINATION_ID:-}"
    if [[ -z "${destination_id}" ]]; then
        destination_id="$(xcrun simctl list devices available | awk '/iPhone/ && /\([0-9A-F-]+\)/ { value=$0; sub(/^.*\(/, "", value); sub(/\).*$/, "", value); print value; exit }')"
    fi
    if [[ -z "${destination_id}" ]]; then
        echo "No available iPhone simulator was found." >&2
        exit 1
    fi
    xcodebuild \
        -project "${repository_root}/Signstr.xcodeproj" \
        -scheme Signstr \
        -destination "platform=iOS Simulator,id=${destination_id}" \
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
        test
}

case "${platform}" in
    ios) run_ios ;;
    macos) run_macos ;;
    all) run_ios; run_macos ;;
    *) echo "Usage: $0 [ios|macos|all]" >&2; exit 64 ;;
esac
