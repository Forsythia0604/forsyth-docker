#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
target_app="${1:?Pass an output .app path}"
[[ "$target_app" == *.app ]] || exit 2
mkdir -p "$target_app/Contents/MacOS" "$target_app/Contents/Resources" "$source_dir/.build/module-cache"
cp "$source_dir/Resources/Info.plist" "$target_app/Contents/Info.plist"
cp "$source_dir/Resources/PreviewIcon.icns" "$target_app/Contents/Resources/"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O \
  -module-cache-path "$source_dir/.build/module-cache" \
  "$source_dir/WindowHelper.swift" "$source_dir/WindowEvents.swift" \
  "$source_dir/../Shared/WindowProtocol.swift" "$source_dir/../Shared/WindowIntent.swift" "$source_dir/../Shared/DirectoryEvents.swift" \
  -o "$target_app/Contents/MacOS/DockWindowHelper"
/usr/bin/codesign --force --sign - --timestamp=none "$target_app"
/usr/bin/codesign --verify --strict "$target_app"
printf '%s\n' "$target_app"
