#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$root/Sources/ProxyGaugeCore/AppVersion.swift"
marketing="$(sed -n 's/.*marketing = "\([^"]*\)".*/\1/p' "$version_file")"
build="$(sed -n 's/.*build = \([0-9][0-9]*\).*/\1/p' "$version_file")"
if [[ ! "$marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build" =~ ^[0-9]+$ ]]; then
    echo "Could not read the version from $version_file." >&2
    exit 1
fi
IFS=. read -r major minor patch <<<"$marketing"
case "${1:-patch}" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    build) ;;
    *) echo "usage: bump-version.sh [major|minor|patch|build]" >&2; exit 2 ;;
esac
next="$major.$minor.$patch"
next_build=$((build + 1))
sed -i '' -e "s/marketing = \"$marketing\"/marketing = \"$next\"/" -e "s/build = $build\$/build = $next_build/" "$version_file"
echo "$next ($next_build)"
