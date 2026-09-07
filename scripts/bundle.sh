#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
version="${1:-0.1.0}"
dist="$root/dist"
app="$dist/TapTap.app"
iconset="$dist/TapTap.iconset"

rm -rf "$dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset" "$dist"
swift build -c release --package-path "$root"
cp "$root/.build/arm64-apple-macosx/release/TapTap" "$app/Contents/MacOS/TapTap"
cp "$root/Packaging/Info.plist" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"

/usr/bin/qlmanage -t -s 1024 -o "$dist" "$root/Resources/hand-wave.svg" >/dev/null 2>&1
cp "$dist/hand-wave.svg.png" "$dist/icon-source.png"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$dist/icon-source.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
done
/usr/bin/sips -z 32 32 "$dist/icon-source.png" --out "$iconset/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 64 64 "$dist/icon-source.png" --out "$iconset/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$dist/icon-source.png" --out "$iconset/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$dist/icon-source.png" --out "$iconset/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$dist/icon-source.png" --out "$iconset/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/TapTap.icns"
rm -rf "$iconset" "$dist/hand-wave.svg.png" "$dist/icon-source.png"
/usr/bin/codesign --force --deep --sign - "$app"
(cd "$dist" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent TapTap.app "TapTap-${version}-macos-arm64.zip")
/usr/bin/shasum -a 256 "$dist/TapTap-${version}-macos-arm64.zip"
