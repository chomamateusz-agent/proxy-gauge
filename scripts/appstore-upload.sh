#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=... TEAM_ID=... scripts/appstore-upload.sh --confirm <bundle id> [--platform macos|ios|all] [--export-only]"
}
confirmed_bundle_id=
platform=all
export_only=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --confirm | --platform)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "$1 needs a value." >&2
                usage >&2
                exit 2
            fi
            if [[ "$1" == --confirm ]]; then confirmed_bundle_id="$2"; else platform="$2"; fi
            shift 2
            ;;
        --export-only) export_only=true; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
missing=()
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH TEAM_ID; do
    if [[ -z "${!name:-}" ]]; then missing+=("$name"); fi
done
if ((${#missing[@]})); then
    echo "Refusing to upload: set ${missing[*]}." >&2
    exit 2
fi
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "Refusing to upload: no API key file at $ASC_KEY_PATH." >&2
    exit 2
fi
key_path="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)/$(basename "$ASC_KEY_PATH")"
if [[ -L "$key_path" ]]; then
    echo "Refusing to upload: use a regular key file, not a symbolic link." >&2
    exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IFS=: read -r -a forbidden_key_dirs <<<"$root${ASC_FORBIDDEN_KEY_DIRS:+:$ASC_FORBIDDEN_KEY_DIRS}"
for forbidden in "${forbidden_key_dirs[@]}"; do
    [[ -n "$forbidden" ]] || continue
    if [[ -d "$forbidden" ]]; then forbidden="$(cd "$forbidden" && pwd -P)"; fi
    if [[ "$key_path" == "${forbidden%/}"/* ]]; then
        echo "Refusing to upload: the key is inside $forbidden. Move it to ~/.appstoreconnect/private_keys/." >&2
        exit 2
    fi
done
key_mode="$(stat -f %Lp "$key_path")"
if (( 8#$key_mode & 8#077 )); then
    echo "Refusing to upload: the API key is readable by other users. Run chmod 600 on it." >&2
    exit 2
fi
if [[ -z "$confirmed_bundle_id" ]]; then
    echo "Refusing to upload without --confirm <bundle id>." >&2
    exit 2
fi
case "$platform" in
    macos | ios | all) ;;
    *) echo "Unknown platform: $platform (macos, ios or all)." >&2; exit 2 ;;
esac

project="$root/Apple/ProxyGauge.xcodeproj"
out="$root/dist/appstore"
options="$out/ExportOptions.plist"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
make -C "$root" generate
settings="$(xcodebuild -project "$project" -target PhoneApp -configuration Release -showBuildSettings 2>/dev/null)"
setting() { awk -v name="$1" '$1 == name { print $3; exit }' <<<"$settings"; }
bundle_id="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
widget_bundle_id="$(setting WIDGET_BUNDLE_IDENTIFIER)"
if [[ -z "$bundle_id" || -z "$widget_bundle_id" ]]; then
    echo "Could not read the bundle identifiers from $project." >&2
    exit 1
fi
if [[ "$(setting IDENTITY_IS_PLACEHOLDER)" != NO ]]; then
    echo "Refusing to upload: set the final identity and IDENTITY_IS_PLACEHOLDER = NO in Apple/Config/Identity.xcconfig." >&2
    exit 2
fi
if [[ "$confirmed_bundle_id" != "$bundle_id" ]]; then
    echo "Refusing to upload: --confirm does not match the project's bundle ID $bundle_id." >&2
    exit 2
fi
if [[ "$TEAM_ID" != "$(setting DEVELOPMENT_TEAM)" ]]; then
    echo "Refusing to upload: TEAM_ID does not match DEVELOPMENT_TEAM." >&2
    exit 2
fi

mkdir -p "$out"
cp "$root/Apple/ExportOptions.plist" "$options"
plutil -replace teamID -string "$TEAM_ID" "$options"
plutil -replace destination -string export "$options"

verify_phone_package() {
    local package="$1" unpacked="$out/PhoneApp-exported" app extension extension_id
    rm -rf "$unpacked"
    mkdir -p "$unpacked"
    ditto -x -k "$package" "$unpacked"
    app="$(find "$unpacked/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
    extension="$app/PlugIns/PhoneWidgets.appex"
    if [[ -z "$app" || ! -d "$extension" ]]; then
        echo "Refusing to upload PhoneApp: the IPA is missing the app or the widget extension." >&2
        exit 1
    fi
    extension_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension/Info.plist")"
    if [[ "$extension_id" != "$widget_bundle_id" ]] || ! codesign --verify --strict "$app" || ! codesign --verify --strict "$extension"; then
        echo "Refusing to upload PhoneApp: invalid signature or widget identity." >&2
        exit 1
    fi
}

prepare() {
    local scheme="$1" destination="$2" archive="$out/$1.xcarchive" export_path="$out/$1" package
    rm -rf "$archive" "$export_path"
    xcodebuild -project "$project" -scheme "$scheme" -configuration Release -destination "$destination" \
        -archivePath "$archive" -derivedDataPath "$root/.build/xcode-appstore" \
        DEVELOPMENT_TEAM="$TEAM_ID" "${auth[@]}" archive
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$export_path" "${auth[@]}"
    if [[ "$scheme" == PhoneApp ]]; then
        package="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
        [[ -n "$package" ]] || { echo "Refusing to upload PhoneApp: export produced no IPA." >&2; exit 1; }
        verify_phone_package "$package"
    else
        package="$(find "$export_path" -maxdepth 1 -type f -name '*.pkg' -print -quit)"
        [[ -n "$package" ]] || { echo "Refusing to upload MacApp: export produced no package." >&2; exit 1; }
    fi
    prepared_packages+=("$package")
}

prepared_packages=()

if [[ "$platform" != macos ]]; then prepare PhoneApp 'generic/platform=iOS'; fi
if [[ "$platform" != ios ]]; then prepare MacApp 'generic/platform=macOS'; fi
if [[ "$export_only" == true ]]; then
    echo "Export and signing checks passed; upload skipped (--export-only)."
    exit 0
fi
for package in "${prepared_packages[@]}"; do
    xcrun altool --upload-package "$package" \
        --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$key_path"
    echo "Uploaded $(basename "$package") to App Store Connect"
done
