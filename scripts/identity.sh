#!/usr/bin/env bash
set -euo pipefail

identity_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Apple/Config/Identity.xcconfig"
resolve() {
    local value name
    value="$(sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$identity_file")"
    if [[ -z "$value" ]]; then
        echo "$1 is not set in $identity_file." >&2
        return 1
    fi
    while [[ "$value" =~ \$\(([A-Z_]+)\) ]]; do
        name="${BASH_REMATCH[1]}"
        value="${value//\$($name)/$(resolve "$name")}"
    done
    printf '%s\n' "$value"
}
if [[ $# -ne 1 || ! "$1" =~ ^[A-Z_]+$ ]]; then
    echo "usage: identity.sh <APP_DISPLAY_NAME|PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM>" >&2
    exit 2
fi
resolve "$1"
