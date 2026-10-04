#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    # 既存mac CIはこのスクリプトを実行するため、Nativeを使うE2Eもここで実行する。
    npm ci
    npm test
fi
args=(-c release --package-path native)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then args+=(--arch arm64 --arch x86_64); fi
swift build "${args[@]}"
binary_dir=$(swift build "${args[@]}" --show-bin-path)
app_path="$PWD/dist/SessionCalendar.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/SessionCalendar" "$app_path/Contents/MacOS/SessionCalendar"
cp native/Support/Info.plist "$app_path/Contents/Info.plist"
cp index.html "$app_path/Contents/Resources/index.html"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app_path"
else
    codesign --force --sign - "$app_path"
fi
codesign --verify --strict --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" dist/SessionCalendar.app.zip
print "Built: $app_path"
