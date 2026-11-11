#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
app_dir="$HOME/Applications"
metadata="${REMEET_LOCAL_INSTALL_METADATA:-$HOME/Library/Application Support/ReMeet/LocalInstall.json}"

usage() {
    printf 'Usage: %s [--app-dir DIRECTORY]\n' "$0"
    printf 'Build ReMeet on this Mac and install it in ~/Applications. The app is not launched.\n'
}

die() {
    printf 'ReMeet: %s\n' "$1" >&2
    exit 1
}

case "$#" in
    0) ;;
    1)
        if [[ "$1" == --help || "$1" == -h ]]; then usage; exit 0; fi
        usage >&2; exit 2 ;;
    2)
        if [[ "$1" != --app-dir || -z "$2" ]]; then usage >&2; exit 2; fi
        app_dir="$2" ;;
    *) usage >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    die 'Local installation requires Apple Silicon and macOS 15 or later.'
fi

umask 077
mkdir -p -- "$app_dir"
app_dir="$(cd "$app_dir" && pwd -P)"
app="$app_dir/ReMeet.app"
if [[ "$app_dir" == /Applications ]]; then
    die 'Use ~/Applications for a local build. The local installer does not replace the system or Homebrew copy.'
fi

user_app_dir="$HOME/Applications"
if [[ -d "$user_app_dir" ]]; then
    user_app_dir="$(cd "$user_app_dir" && pwd -P)"
fi
if [[ "$app_dir" == "$user_app_dir" && ( -e /Applications/ReMeet.app || -L /Applications/ReMeet.app ) ]]; then
    printf '%s\n' 'A ReMeet copy already exists in /Applications. Remove that copy before switching to a local build.' >&2
    printf '%s\n' 'If you installed it with Homebrew, run: brew uninstall --cask Salah1St/tap/remeet' >&2
    exit 1
fi

metadata_dir="$(dirname -- "$metadata")"
mkdir -p -- "$metadata_dir"
metadata_dir="$(cd "$metadata_dir" && pwd -P)"
metadata="$metadata_dir/$(basename -- "$metadata")"
lock="$metadata_dir/.remeet-local-install.lock"
if ! mkdir -- "$lock" 2>/dev/null; then
    die "Another local installation is in progress, or a previous installation left $lock."
fi
stage=""
receipt_stage=""
installing=false
completed=false
cleanup() {
    if [[ -n "$stage" && "$completed" == false ]]; then
        # An error after moving the new app into place must restore the previous copy.
        if [[ "$installing" == true && ! -e "$stage/ReMeet.app" && -e "$app" ]]; then
            if ! mv -h "$app" "$stage/ReMeet.app"; then
                printf 'Could not undo app replacement. The staging folder is %s.\n' "$stage" >&2
                stage=""
            fi
        fi
        if [[ -n "$stage" && -d "$stage/previous.app" ]]; then
            if [[ -e "$app" || -L "$app" ]] || ! mv -h "$stage/previous.app" "$app"; then
                printf 'Could not restore the previous app. Its backup is %s/previous.app.\n' "$stage" >&2
                stage=""
            fi
        fi
    fi
    if [[ -n "$stage" ]]; then rm -rf -- "$stage"; fi
    if [[ -n "$receipt_stage" ]]; then rm -f -- "$receipt_stage"; fi
    rmdir -- "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -L "$metadata" || ( -e "$metadata" && ! -f "$metadata" ) ]]; then
    die "Cannot use the local installation receipt at $metadata."
fi
recorded_app=""
if [[ -f "$metadata" ]]; then
    recorded_app="$(/usr/bin/plutil -extract appPath raw "$metadata")" ||
        die "The local installation receipt is invalid: $metadata"
fi
if [[ -n "$recorded_app" && "$recorded_app" != "$app" && ( -e "$recorded_app" || -L "$recorded_app" ) ]]; then
    die "The current local installation is at $recorded_app. Update that location or move that app first."
fi
if [[ -L "$app" ]]; then
    die "The destination is a symbolic link: $app"
fi
if [[ -e "$app" ]]; then
    bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$bundle_id" != app.remeet.mac || "$recorded_app" != "$app" ]]; then
        die "The destination already contains an app that this installer does not manage: $app"
    fi
    /usr/bin/codesign --verify --strict --deep "$app"
fi

stage="$(mktemp -d "$app_dir/.remeet-install.XXXXXX")"
receipt_stage="$(mktemp "$metadata_dir/.LocalInstall.XXXXXX")"
/usr/bin/plutil -create xml1 "$receipt_stage"
/usr/bin/plutil -insert sourcePath -string "$source_dir" "$receipt_stage"
/usr/bin/plutil -insert appPath -string "$app" "$receipt_stage"
/usr/bin/plutil -convert json "$receipt_stage"

export PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:/opt/homebrew/bin:/usr/local/bin"
REMEET_SIGN_IDENTITY=- REMEET_NOTARY_PROFILE= REMEET_SKIP_WORKERS=0 "$source_dir/scripts/build.sh"
/usr/bin/ditto "$source_dir/dist/ReMeet.app" "$stage/ReMeet.app"
/usr/bin/codesign --verify --strict --deep "$stage/ReMeet.app"

if [[ -e "$app" ]]; then
    mv -h "$app" "$stage/previous.app"
fi
installing=true
mv -h "$stage/ReMeet.app" "$app"
mv -fh "$receipt_stage" "$metadata"
completed=true

printf 'Installed %s\n' "$app"
printf 'CLI %s/Contents/MacOS/remeet\n' "$app"
