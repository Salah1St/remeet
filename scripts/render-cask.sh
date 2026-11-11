#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ $# != 3 || ! "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! -f "$3" ]]; then
    printf 'Usage: %s OWNER/REPO VERSION /path/to/ReMeet-VERSION-arm64.zip\n' "$0" >&2
    exit 2
fi

repository="$1" version="$2" archive="$3"
checksum="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
sed -e "s|@REPOSITORY@|$repository|g" -e "s|@VERSION@|$version|g" -e "s|@SHA256@|$checksum|g" \
    "$project_dir/packaging/remeet.rb.in"
