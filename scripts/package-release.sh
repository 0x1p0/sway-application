#!/bin/bash
# Build a fresh universal app and verify ZIP and DMG downloads before upload.
# Never creates a tag, commits source, or publishes to the network.
set -euo pipefail
verify_universal() {
    local architectures required
    architectures="$(xcrun lipo -archs "$1")"
    for required in arm64 x86_64; do
        case " $architectures " in
            *" $required "*) ;;
            *) printf 'Missing %s executable slice.\n' "$required" >&2; return 1 ;;
        esac
    done
}
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
cd "$project_directory"
version="$(bash scripts/release-version.sh "${1:-}")"
release_directory="$project_directory/build/releases/v$version"
if [[ -e "$release_directory" ]]; then
    printf 'Release output already exists: %s\nMove it aside before rebuilding; existing artifacts are never overwritten.\n' "$release_directory" >&2
    exit 2
fi
if [[ ! -s "releases/v$version.md" ]]; then
    printf 'Missing release notes for v%s.\n' "$version" >&2
    exit 2
fi
SWAY_ARCH=universal bash scripts/build.sh
bundle="$project_directory/build/Sway.app"
executable="$bundle/Contents/MacOS/Sway"
plist_tool=/usr/libexec/PlistBuddy
[[ "$("$plist_tool" -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")" == "$version" ]]
[[ "$("$plist_tool" -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" == "com.trackpadcontrol.app" ]]
verify_universal "$executable"
codesign --verify --deep --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist"

staging="$(mktemp -d "$project_directory/build/ReleasePackage.XXXXXX")"
mkdir -p "$staging/artifacts" "$staging/verify" "$project_directory/build/releases"
archive="Sway-$version-macos-universal.zip"
ditto -c -k --keepParent --norsrc --noextattr "$bundle" "$staging/artifacts/$archive"
ditto -x -k "$staging/artifacts/$archive" "$staging/verify"
codesign --verify --deep --strict "$staging/verify/Sway.app"
verify_universal "$staging/verify/Sway.app/Contents/MacOS/Sway"
cmp "$executable" "$staging/verify/Sway.app/Contents/MacOS/Sway"

disk_image="Sway-$version-macos-universal.dmg"
bash scripts/create-dmg.sh "$bundle" "$staging/artifacts/$disk_image"

(
    cd "$staging/artifacts"
    checksum_files=("$archive" "$disk_image")
    if [[ -s appcast.xml ]]; then checksum_files+=(appcast.xml); fi
    shasum -a 256 "${checksum_files[@]}" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
if [[ "${SWAY_DEFER_UPDATE_SIGNING:-0}" != "1" ]]; then
    bash scripts/sign-release.sh "$staging/artifacts" "v$version"
fi
mv "$staging/artifacts" "$release_directory"
printf '\nVerified release artifacts: %s\n' "$release_directory"
printf 'Signing: ad-hoc; not notarized. No release has been published by this script.\n'
