#!/bin/bash
# Package one square PNG into every size referenced by the macOS asset catalog.
# sips preserves the generated alpha; no custom masking or artwork is added.
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
asset_directory="$project_directory/Sway/Assets.xcassets/AppIcon.appiconset"
master="$asset_directory/icon_1024x1024.png"
source_image="${1:-$master}"

if [[ ! -f "$source_image" ]]; then
    printf 'Icon source does not exist: %s\n' "$source_image" >&2
    exit 2
fi
width="$(sips -g pixelWidth "$source_image" | awk '/pixelWidth:/ {print $2}')"
height="$(sips -g pixelHeight "$source_image" | awk '/pixelHeight:/ {print $2}')"
if [[ "$width" != "$height" || "$width" -lt 1024 ]]; then
    printf 'Provide a square PNG at least 1024 pixels wide.\n' >&2
    exit 2
fi
format="$(sips -g format "$source_image" | awk '/format:/ {print $2}')"
if [[ "$format" != "png" ]]; then
    printf 'Provide PNG artwork to preserve transparency.\n' >&2
    exit 2
fi

if [[ "$source_image" != "$master" || "$width" != "1024" ]]; then
    sips -z 1024 1024 "$source_image" --out "$master" >/dev/null
fi
for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$asset_directory/icon_${size}x${size}.png" >/dev/null
done
printf 'Updated AppIcon: 16, 32, 64, 128, 256, 512, and 1024 pixels.\n'
