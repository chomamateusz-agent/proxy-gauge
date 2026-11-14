#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple="$root/Apple"
version_file="$root/Sources/ProxyGaugeCore/AppVersion.swift"
marketing="$(sed -n 's/.*marketing = "\([^"]*\)".*/\1/p' "$version_file")"
build="$(sed -n 's/.*build = \([0-9][0-9]*\).*/\1/p' "$version_file")"
if [[ ! "$marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build" =~ ^[0-9]+$ ]]; then
    echo "Could not read the version from $version_file." >&2
    exit 1
fi
if ! command -v xcodegen >/dev/null; then
    echo "XcodeGen is not installed: brew install xcodegen" >&2
    exit 1
fi
cat > "$apple/Config/Version.generated.xcconfig" <<XCCONFIG
MARKETING_VERSION = $marketing
CURRENT_PROJECT_VERSION = $build
XCCONFIG
xcodegen generate --spec "$apple/project.yml" --project "$apple" --quiet
echo "Generated $apple/ProxyGauge.xcodeproj ($marketing, build $build)"
