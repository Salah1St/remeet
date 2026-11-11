#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$project_dir"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf 'ReMeet requires Apple Silicon and macOS 15 or later.\n' >&2
    exit 1
fi
macos="$(sw_vers -productVersion)"
if (( ${macos%%.*} < 15 )); then
    printf 'ReMeet requires macOS 15 or later.\n' >&2
    exit 1
fi

version="${REMEET_VERSION:-$(cat VERSION)}"
sign_identity="${REMEET_SIGN_IDENTITY:--}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'REMEET_VERSION must be a version such as 0.1.0.\n' >&2
    exit 1
fi
dist="$project_dir/dist"
mkdir -p "$dist"
if ! mkdir "$dist/.build-lock" 2>/dev/null; then
    printf 'Another ReMeet build is publishing to %s.\n' "$dist" >&2
    exit 1
fi
stage="$(mktemp -d "$dist/.stage.XXXXXX")"
cleanup() {
    rm -rf "$stage"
    rmdir "$dist/.build-lock"
}
trap cleanup EXIT

app="$stage/ReMeet.app"
extension="$app/Contents/PlugIns/ReMeetWidget.appex"
mkdir -p "$app/Contents"/{MacOS,Helpers,Frameworks,Resources} "$extension/Contents/MacOS"
install -m 644 Resources/Info.plist "$app/Contents/Info.plist"
install -m 644 Resources/Widget-Info.plist "$extension/Contents/Info.plist"
for plist in "$app/Contents/Info.plist" "$extension/Contents/Info.plist"; do
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$version" "$plist"
done

module_cache="$project_dir/.build/remeet-module-cache"
export CLANG_MODULE_CACHE_PATH="$module_cache" SWIFT_MODULE_CACHE_PATH="$module_cache"
swift build -c release --product ReMeet
swift build -c release --product remeet
bin_dir="$(swift build -c release --show-bin-path)"
install -m 755 "$bin_dir/ReMeet" "$bin_dir/remeet" "$app/Contents/MacOS/"

xcrun swiftc -O -parse-as-library -application-extension -module-name ReMeetWidget \
    -target arm64-apple-macosx15.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension \
    Sources/ReMeetWidget/ReMeetWidget.swift Sources/MeetingCore/WidgetState.swift \
    -o "$extension/Contents/MacOS/ReMeetWidget"

if [[ "${REMEET_SKIP_WORKERS:-0}" != 1 ]]; then
    workers="$("$project_dir/scripts/build-workers.sh")"
    cp -R "$workers/Helpers/." "$app/Contents/Helpers/"
    cp -R "$workers/Frameworks/." "$app/Contents/Frameworks/"
    cp -R "$workers/Licenses" "$app/Contents/Resources/"
elif [[ "$sign_identity" != - ]]; then
    printf 'A distribution build must include the inference workers.\n' >&2
    exit 1
fi

signing=(--force --sign "$sign_identity")
if [[ "$sign_identity" == - ]]; then
    signing+=(--timestamp=none)
else
    signing+=(--timestamp --options runtime)
fi

shopt -s nullglob
for worker in "$app/Contents/Frameworks/"*.dylib "$app/Contents/Helpers/"*; do
    codesign "${signing[@]}" "$worker"
done
codesign "${signing[@]}" --identifier app.remeet.cli "$app/Contents/MacOS/remeet"

install -m 644 Resources/App.entitlements "$stage/App.entitlements"
install -m 644 Resources/Widget.entitlements "$stage/Widget.entitlements"
if [[ "$sign_identity" != - ]]; then
    signing_details="$(codesign -dv --verbose=4 "$app/Contents/MacOS/remeet" 2>&1)"
    actual_team="$(sed -n 's/^TeamIdentifier=//p' <<< "$signing_details")"
    team="${REMEET_TEAM_ID:-$actual_team}"
    if [[ ! "$team" =~ ^[A-Z0-9]{10}$ || "$team" != "$actual_team" ]]; then
        printf 'REMEET_TEAM_ID must match the Apple team used for signing.\n' >&2
        exit 1
    fi
    group="$team.app.remeet.shared"
    plutil -insert ReMeetAppGroup -string "$group" "$app/Contents/Info.plist"
    plutil -insert ReMeetAppGroup -string "$group" "$extension/Contents/Info.plist"
    for entitlements in "$stage/App.entitlements" "$stage/Widget.entitlements"; do
        /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' \
            -c "Add :com.apple.security.application-groups:0 string $group" "$entitlements"
    done
fi

codesign "${signing[@]}" --entitlements "$stage/Widget.entitlements" "$extension"
codesign "${signing[@]}" --entitlements "$stage/App.entitlements" "$app"
codesign --verify --strict --deep "$app"

archive="ReMeet-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$archive"
if [[ -n "${REMEET_NOTARY_PROFILE:-}" ]]; then
    if [[ "$sign_identity" == - ]]; then
        printf 'Notarization requires a Developer ID signing identity.\n' >&2
        exit 1
    fi
    notary=(--keychain-profile "$REMEET_NOTARY_PROFILE")
    if [[ -n "${REMEET_NOTARY_KEYCHAIN:-}" ]]; then
        notary+=(--keychain "$REMEET_NOTARY_KEYCHAIN")
    fi
    xcrun notarytool submit "$stage/$archive" "${notary[@]}" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose "$app"
    rm "$stage/$archive"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$archive"
fi

(cd "$stage" && shasum -a 256 "$archive" > "$archive.sha256")
if [[ -e "$dist/ReMeet.app" ]]; then
    if [[ -L "$dist/ReMeet.app" || "$(plutil -extract CFBundleIdentifier raw "$dist/ReMeet.app/Contents/Info.plist")" != app.remeet.mac ]]; then
        printf 'Another app occupies %s.\n' "$dist/ReMeet.app" >&2
        exit 1
    fi
    mv "$dist/ReMeet.app" "$stage/previous.app"
fi
if ! mv "$app" "$dist/ReMeet.app"; then
    if [[ -d "$stage/previous.app" ]]; then
        mv "$stage/previous.app" "$dist/ReMeet.app"
    fi
    exit 1
fi
mv -f "$stage/$archive" "$stage/$archive.sha256" "$dist/"
printf 'App  %s\nCLI  %s\nZIP  %s\n' \
    "$dist/ReMeet.app" "$dist/ReMeet.app/Contents/MacOS/remeet" "$dist/$archive"
