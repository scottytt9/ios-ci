#!/usr/bin/env bash
set -euo pipefail

ios_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vendor="$ios_root/Vendor"
version="3.7.5"
digest="a76f7a6cfcde4209b56f943e6e18400659d8a7a93ff482f8b1d059468d11e6be"
url="https://download.videolan.org/cocoapods/prod/MobileVLCKit-3.7.5-a213fd11-6de05adc.tar.xz"
stamp="$vendor/.mobilevlckit"

if [[ -f "$stamp" && "$(cat "$stamp")" == "$digest" &&
      -f "$vendor/MobileVLCKit.xcframework/Info.plist" && -f "$vendor/MobileVLCKit-LICENSE.txt" ]]; then
    exit 0
fi

temp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
staging="$(mktemp -d "$temp_root/interlude-vlc.XXXXXXXX")"
[[ "$staging" == "$temp_root"/interlude-vlc.* && -d "$staging" && ! -L "$staging" ]]
trap 'rm -rf -- "$staging"' EXIT
archive="${INTERLUDE_VLC_ARCHIVE:-$staging/mobilevlckit.tar.xz}"
if [[ -z "${INTERLUDE_VLC_ARCHIVE:-}" ]]; then
    curl --fail --location --silent --show-error --retry 2 "$url" -o "$archive"
fi
if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 < "$archive")"
else
    actual="$(sha256sum < "$archive")"
fi
if [[ "${actual%% *}" != "$digest" ]]; then
    echo "MobileVLCKit $version failed checksum verification." >&2
    exit 1
fi

tar -xJf - -C "$staging" MobileVLCKit-binary/MobileVLCKit.xcframework MobileVLCKit-binary/COPYING.txt < "$archive"
mkdir -p "$vendor"
if [[ -e "$vendor/MobileVLCKit.xcframework" ]]; then
    mv "$vendor/MobileVLCKit.xcframework" "$staging/previous.xcframework"
fi
mv "$staging/MobileVLCKit-binary/MobileVLCKit.xcframework" "$vendor/"
mv "$staging/MobileVLCKit-binary/COPYING.txt" "$vendor/MobileVLCKit-LICENSE.txt"
printf '%s\n' "$digest" > "$stamp"
