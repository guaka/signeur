#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

tag="${1:-${GITHUB_REF_NAME:-}}"
if [[ -z "$tag" ]]; then
  echo "Usage: $0 v<version>" >&2
  exit 64
fi

if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Release tag must have the form v0.1.0; got: $tag" >&2
  exit 1
fi

configured_versions="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' project.yml | sort -u)"
expected_version="${tag#v}"

if [[ "$configured_versions" != "$expected_version" ]]; then
  echo "Tag $tag does not match MARKETING_VERSION in project.yml ($configured_versions)." >&2
  exit 1
fi

echo "$expected_version"
