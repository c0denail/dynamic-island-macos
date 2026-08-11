#!/bin/bash

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
output_dir="$project_dir/dist"
app_dir="$output_dir/Dynamic Island.app"
adapter_commit="8c8c1fa4820681fd4bbd6a17ce0a5655e1f4ebe7"
adapter_dir="$project_dir/.build/mediaremote-mini-$adapter_commit"
universal_dir="$project_dir/.build/universal-$configuration"
arm_scratch="$universal_dir/swift-arm64"
x86_scratch="$universal_dir/swift-x86_64"
mini_arm_dir="build/mediaremote-mini-arm64"
mini_x86_dir="build/mediaremote-mini-x86_64"
preferred_development_identity="AE775513E31FC2599BBFB8D7747E690DE558FC90"

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    code_sign_identity="$CODE_SIGN_IDENTITY"
elif security find-identity -v -p codesigning | grep -F "$preferred_development_identity" >/dev/null; then
    code_sign_identity="$preferred_development_identity"
else
    code_sign_identity="$(security find-identity -v -p codesigning | awk '/Apple Development:/ && !found { print $2; found=1 }')"
    code_sign_identity="${code_sign_identity:--}"
fi

code_sign_arguments=(--force --sign "$code_sign_identity")
if [[ "$code_sign_identity" != "-" ]]; then
    code_sign_arguments+=(--timestamp)
fi

cd "$project_dir"
swift build -c "$configuration" --triple arm64-apple-macosx14.0 --scratch-path "$arm_scratch"
swift build -c "$configuration" --triple x86_64-apple-macosx14.0 --scratch-path "$x86_scratch"
arm_binary_dir="$(swift build -c "$configuration" --triple arm64-apple-macosx14.0 --scratch-path "$arm_scratch" --show-bin-path)"
x86_binary_dir="$(swift build -c "$configuration" --triple x86_64-apple-macosx14.0 --scratch-path "$x86_scratch" --show-bin-path)"

if [[ ! -d "$adapter_dir/.git" ]]; then
    git clone --quiet https://github.com/kirtan-shah/nowplaying-cli.git "$adapter_dir"
fi
if [[ "$(git -C "$adapter_dir" rev-parse HEAD)" != "$adapter_commit" ]]; then
    git -C "$adapter_dir" fetch --quiet origin "$adapter_commit"
    git -C "$adapter_dir" checkout --quiet "$adapter_commit"
fi
make -s -B -C "$adapter_dir" MINI_BUILD_DIR="$mini_arm_dir" CFLAGS="-O3 -arch arm64" "$mini_arm_dir/MediaRemoteMini.dylib"
make -s -B -C "$adapter_dir" MINI_BUILD_DIR="$mini_x86_dir" CFLAGS="-O3 -arch x86_64" "$mini_x86_dir/MediaRemoteMini.dylib"

rm -rf "$app_dir"
mkdir -p \
    "$app_dir/Contents/MacOS" \
    "$app_dir/Contents/Resources/NowPlaying" \
    "$app_dir/Contents/Helpers" \
    "$app_dir/Contents/Library/PrivilegedHelperTools" \
    "$app_dir/Contents/Library/LaunchDaemons"
lipo -create \
    "$arm_binary_dir/DynamicIslandMac" \
    "$x86_binary_dir/DynamicIslandMac" \
    -output "$app_dir/Contents/MacOS/DynamicIslandMac"
lipo -create \
    "$arm_binary_dir/DynamicIslandPowerHelper" \
    "$x86_binary_dir/DynamicIslandPowerHelper" \
    -output "$app_dir/Contents/Library/PrivilegedHelperTools/dev.c0denail.DynamicIslandMac.PowerHelper"
ditto "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
ditto \
    "$project_dir/Resources/dev.c0denail.DynamicIslandMac.PowerHelper.plist" \
    "$app_dir/Contents/Library/LaunchDaemons/dev.c0denail.DynamicIslandMac.PowerHelper.plist"
ditto "$adapter_dir/scripts/mediaremote-mini.pl" "$app_dir/Contents/Resources/NowPlaying/mediaremote-mini.pl"
lipo -create \
    "$adapter_dir/$mini_arm_dir/MediaRemoteMini.dylib" \
    "$adapter_dir/$mini_x86_dir/MediaRemoteMini.dylib" \
    -output "$app_dir/Contents/Resources/NowPlaying/MediaRemoteMini.dylib"
ditto "$project_dir/Resources/MediaRemoteMini-LICENSE.txt" "$app_dir/Contents/Resources/NowPlaying/LICENSE.txt"
clang -arch arm64 -fobjc-arc -O2 -framework Cocoa \
    "$project_dir/Resources/NowPlayingControl.m" \
    -o "$universal_dir/NowPlayingControl-arm64"
clang -arch x86_64 -fobjc-arc -O2 -framework Cocoa \
    "$project_dir/Resources/NowPlayingControl.m" \
    -o "$universal_dir/NowPlayingControl-x86_64"
lipo -create \
    "$universal_dir/NowPlayingControl-arm64" \
    "$universal_dir/NowPlayingControl-x86_64" \
    -output "$app_dir/Contents/Helpers/NowPlayingControl"
chmod +x "$app_dir/Contents/MacOS/DynamicIslandMac"
chmod +x "$app_dir/Contents/Helpers/NowPlayingControl"
chmod +x "$app_dir/Contents/Library/PrivilegedHelperTools/dev.c0denail.DynamicIslandMac.PowerHelper"

codesign "${code_sign_arguments[@]}" "$app_dir/Contents/Library/PrivilegedHelperTools/dev.c0denail.DynamicIslandMac.PowerHelper"
codesign --deep "${code_sign_arguments[@]}" "$app_dir"

echo "Code signing identity: $code_sign_identity"
echo "$app_dir"
