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

readonly exclusions_json="${output_dir}/coverage-exclusions.json"
(
    cd "${repository_root}"
    if command -v rg >/dev/null 2>&1; then
        rg -n --no-heading 'coverage:ignore' App Data NIP46 Nostr Shared Wallet
    else
        grep -R -n -H 'coverage:ignore' App Data NIP46 Nostr Shared Wallet
    fi
) | jq -R -s '
    split("\n")
    | map(
        select(length > 0)
        | capture("^(?<file>[^:]+):(?<line>[0-9]+):(?<source>.*)$")
        | {file, line: (.line | tonumber), scope: (if (.source | contains("coverage:ignore-region")) then "region" else "line" end)}
    )
' > "${exclusions_json}"

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
    --arg generated "$(date -u '+%Y-%m-%d %H:%M')" \
    --slurpfile exclusions "${exclusions_json}" \
    -f "${coverage_assets}/index.jq" \
    "${coverage_json}" > "${output_dir}/index.html"

touch "${output_dir}/.nojekyll"

jq -r --arg root "${repository_root}/" --slurpfile exclusions "${exclusions_json}" '
    def metric_sum($items; $name):
        reduce $items[] as $item (
            {covered: 0, count: 0};
            .covered += ($item.summary[$name].covered // 0)
            | .count += ($item.summary[$name].count // 0)
        );
    def line_metric($items; $excluded):
        [
            $items[] as $file
            | $file.segments[]
            | select(.[3] == true)
            | {file: $file.relative, line: .[0], count: .[2]}
            | . as $entry
            | select(any($excluded[]; .scope != "region" and .file == $entry.file and .line == $entry.line) | not)
        ]
        | group_by([.file, .line])
        | map({covered: ((map(.count) | max) > 0)})
        | {covered: (map(select(.covered)) | length), count: length};
    def source_function:
        # Swift mangling tokens for closures, default arguments, autoclosures, and property initializers.
        (.name | test("cf[UuA]|XE[fF][uU]|vpfi") | not);
    def function_metric($all_functions; $root; $items):
        [
            $all_functions[]
            | select(source_function)
            | . as $function
            | select(any($items[]; . as $file | any($function.filenames[]; . == ($root + $file.relative))))
        ]
        | unique_by(.name)
        | {covered: (map(select(.count > 0)) | length), count: length};
    def region_metric($all_functions; $root; $items; $excluded):
        [
            $all_functions[]
            | select(source_function)
            | . as $function
            | .regions[]
            | select((.[7] // 0) == 0)
            | {name: $function.name, file: (($function.filenames[.[5]] // $function.filenames[0]) | ltrimstr($root)), line: .[0], column: .[1], endLine: .[2], endColumn: .[3], count: .[4]}
            | . as $region
            | select(any($items[]; .relative == $region.file))
            | select(any($excluded[]; .file == $region.file and .line == $region.line) | not)
        ]
        | unique_by([.name, .file, .line, .column, .endLine, .endColumn])
        | {covered: (map(select(.count > 0)) | length), count: length};
    def percentage($metric):
        if $metric.count == 0 then "n/a"
        else (((($metric.covered * 10000 / $metric.count) | floor) / 100) | tostring) + "%"
        end;
    .data[0] as $coverage
    | $coverage.functions as $allFunctions
    | [
        $coverage.files[]
        | select(.filename | startswith($root))
        | . + {relative: (.filename | ltrimstr($root))}
        | select(.relative | startswith(".build/") | not)
        | select(.relative | startswith("Tests/") | not)
    ] as $files
    | (line_metric($files; $exclusions[0])) as $lines
    | (function_metric($allFunctions; $root; $files)) as $functions
    | (region_metric($allFunctions; $root; $files; $exclusions[0])) as $regions
    | [
        "## Code coverage",
        "",
        "SignstrCore sources only; tests, dependencies, compiler-generated functions, skipped regions, and explicitly documented non-testable code are excluded.",
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
            | (line_metric($group; $exclusions[0])) as $metric
            | "| \(($group[0].relative | split("/")[0])) | \($metric.covered) | \($metric.count) | \(percentage($metric)) |"
        )
    )
    | .[]
' "${coverage_json}" > "${output_dir}/summary.md"

cat "${output_dir}/summary.md"
