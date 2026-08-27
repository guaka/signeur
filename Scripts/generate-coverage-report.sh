#!/usr/bin/env bash

set -euo pipefail

readonly output_dir="${1:-coverage-report}"
readonly repository_root="$(git rev-parse --show-toplevel)"
readonly coverage_assets="${repository_root}/Scripts/coverage-site"
readonly coverage_json="$(find "${repository_root}/.build" -path '*/codecov/signstr.json' -type f -print -quit)"

if [[ -z "${coverage_json}" ]]; then
    echo "Coverage JSON not found. Run 'swift test --enable-code-coverage' first." >&2
    exit 1
fi

readonly codecov_dir="$(dirname "${coverage_json}")"
readonly build_dir="$(dirname "${codecov_dir}")"
readonly profile_data="${codecov_dir}/default.profdata"
readonly test_binary="${build_dir}/signstrPackageTests.xctest/Contents/MacOS/signstrPackageTests"

if [[ ! -f "${profile_data}" || ! -x "${test_binary}" ]]; then
    echo "Coverage profile or instrumented test binary is missing." >&2
    exit 1
fi

mkdir -p "${output_dir}"
cp "${coverage_json}" "${output_dir}/coverage.json"

xcrun llvm-cov show "${test_binary}" \
    -instr-profile="${profile_data}" \
    -format=html \
    -output-dir="${output_dir}" \
    -ignore-filename-regex='(/Tests/|/.build/)' \
    -show-instantiations=false \
    -show-line-counts-or-regions

cp "${repository_root}/iOSApp/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png" \
    "${output_dir}/signstr-icon.png"
cp "${coverage_assets}/coverage.css" "${output_dir}/coverage.css"
"${coverage_assets}/node_modules/.bin/esbuild" \
    "${coverage_assets}/nip46-tester.source.mjs" \
    --bundle \
    --platform=browser \
    --format=esm \
    --target=es2022 \
    --minify \
    --legal-comments=inline \
    --outfile="${output_dir}/nip46-tester.mjs"

jq -r \
    --arg root "${repository_root}/" \
    --arg generated "$(date -u '+%Y-%m-%d %H:%M UTC')" \
    -f "${coverage_assets}/index.jq" \
    "${coverage_json}" > "${output_dir}/index.html"

touch "${output_dir}/.nojekyll"

jq -r --arg root "${repository_root}/" '
    def metric_sum($items; $name):
        reduce $items[] as $item (
            {covered: 0, count: 0};
            .covered += ($item.summary[$name].covered // 0)
            | .count += ($item.summary[$name].count // 0)
        );
    def percentage($metric):
        if $metric.count == 0 then "n/a"
        else (((($metric.covered * 10000 / $metric.count) | floor) / 100) | tostring) + "%"
        end;
    [
        .data[0].files[]
        | select(.filename | startswith($root))
        | . + {relative: (.filename | ltrimstr($root))}
        | select(.relative | startswith(".build/") | not)
        | select(.relative | startswith("Tests/") | not)
    ] as $files
    | (metric_sum($files; "lines")) as $lines
    | (metric_sum($files; "functions")) as $functions
    | (metric_sum($files; "regions")) as $regions
    | [
        "## Code coverage",
        "",
        "SignstrCore sources only; tests, generated files, and dependencies are excluded.",
        "",
        "| Metric | Covered | Total | Coverage |",
        "| --- | ---: | ---: | ---: |",
        "| Lines | \($lines.covered) | \($lines.count) | \(percentage($lines)) |",
        "| Functions | \($functions.covered) | \($functions.count) | \(percentage($functions)) |",
        "| Regions | \($regions.covered) | \($regions.count) | \(percentage($regions)) |",
        "",
        "### Line coverage by area",
        "",
        "| Area | Covered | Total | Coverage |",
        "| --- | ---: | ---: | ---: |"
    ] + (
        $files
        | sort_by(.relative | split("/")[0])
        | group_by(.relative | split("/")[0])
        | map(
            . as $group
            | (metric_sum($group; "lines")) as $metric
            | "| \(($group[0].relative | split("/")[0])) | \($metric.covered) | \($metric.count) | \(percentage($metric)) |"
        )
    )
    | .[]
' "${coverage_json}" > "${output_dir}/summary.md"

cat "${output_dir}/summary.md"
