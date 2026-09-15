#!/bin/zsh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="$root/.build"
app="$build_dir/bundle/Takeform Native Preview.app"
binary="$build_dir/arm64-apple-macosx/release/NativePreviewHost"
resources="$build_dir/arm64-apple-macosx/release/NativePreviewHost_NativePreviewHost.bundle"

cd "$root"
swift build -c release
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/NativePreviewHost"
cp -R "$resources" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>NativePreviewHost</string>
<key>CFBundleIdentifier</key><string>com.takeform.native-preview-host</string>
<key>CFBundleName</key><string>Takeform Native Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
test -f "$app/Contents/Resources/NativePreviewHost_NativePreviewHost.bundle/preview-helper.mjs"
test -f "$app/Contents/Resources/NativePreviewHost_NativePreviewHost.bundle/diagnostic.html"
print -- "$app"
