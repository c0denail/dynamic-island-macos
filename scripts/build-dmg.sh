#!/bin/bash

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_dir/dist/Dynamic Island.app"
dmg_path="$project_dir/dist/Dynamic-Island-for-macOS-v1.0.9.dmg"
temp_root="$(mktemp -d /tmp/dynamic-island-dmg.XXXXXX)"
stage_dir="$temp_root/Dynamic Island"

cleanup() {
    rm -rf "$temp_root"
}
trap cleanup EXIT

"$project_dir/scripts/build-app.sh" release
codesign --verify --deep --strict --verbose=2 "$app_path"

mkdir -p "$stage_dir"
ditto "$app_path" "$stage_dir/Dynamic Island.app"
ditto "$project_dir/Resources/DMG-Install.txt" "$stage_dir/Kurulum - İlk Açılış.txt"
ln -s /Applications "$stage_dir/Applications"

rm -f "$dmg_path"
hdiutil create \
    -volname "Dynamic Island" \
    -srcfolder "$stage_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

hdiutil verify "$dmg_path"
echo "$dmg_path"
