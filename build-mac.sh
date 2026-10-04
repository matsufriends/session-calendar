#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
args=(-c release --package-path native)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then args+=(--arch arm64 --arch x86_64); fi
swift build "${args[@]}"
binary_dir=$(swift build "${args[@]}" --show-bin-path)
app_path="$PWD/dist/MornSessionCalendar.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/MornSessionCalendar" "$app_path/Contents/MacOS/MornSessionCalendar"
cp native/Support/Info.plist "$app_path/Contents/Info.plist"
cp index.html "$app_path/Contents/Resources/index.html"
if [[ -n "${VERSION:-}" ]]; then
    [[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid VERSION'; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$app_path/Contents/Info.plist"
fi
codesign --force --sign - "$app_path"
print "Built: $app_path"
