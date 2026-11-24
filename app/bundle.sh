#!/bin/bash
# Собирает Agentmeister.app из уже собранного бинарника SwiftPM: Info.plist с bundle id и схемой ссылок
# agentmeister://, иконка из share/agentmeister/icon.png, подпись. Сам swift build сюда не входит: в proxy-сессии
# его запускает host-run, а в обычном терминале make app.
#
#   ./bundle.sh [бинарник] [папка назначения]
#
# По умолчанию берет release-сборку, если она есть, иначе debug, и кладет приложение в app/build.
# Подпись: AGENTMEISTER_SIGN=<имя сертификата> или первая Developer ID Application/Apple Development из связки,
# иначе ad-hoc. Разрешения macOS привязаны к подписи, поэтому одна и та же подпись между сборками важна.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
bin=${1:-}
if [[ -z $bin ]]; then
  for candidate in "$here/.build/out/Products/Release/Agentmeister" "$here/.build/release/Agentmeister" \
                   "$here/.build/out/Products/Debug/Agentmeister" "$here/.build/debug/Agentmeister"; do
    if [[ -x $candidate ]]; then bin=$candidate; break; fi
  done
fi
[[ -n $bin && -x $bin ]] || { echo "bundle.sh: нет собранного Agentmeister, сначала swift build" >&2; exit 1; }
out=${2:-$here/build}
app=$out/Agentmeister.app
version=$(cat "$root/VERSION" 2>/dev/null || echo 0)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage=$tmp/Agentmeister.app
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$bin" "$stage/Contents/MacOS/Agentmeister"

icon=$root/share/agentmeister/icon.png
if [[ -f $icon ]]; then
  set=$tmp/AppIcon.iconset
  mkdir -p "$set"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$icon" --out "$set/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$icon" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$stage/Contents/Resources/AppIcon.icns"
fi

cat > "$stage/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.agentmeister.app</string>
  <key>CFBundleName</key><string>Agentmeister</string>
  <key>CFBundleDisplayName</key><string>Agentmeister</string>
  <key>CFBundleExecutable</key><string>Agentmeister</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.agentmeister.app</string>
      <key>CFBundleURLSchemes</key><array><string>agentmeister</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

identity=${AGENTMEISTER_SIGN:-}
if [[ -z $identity ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p; s/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1 || true)
fi
codesign --force --sign "${identity:--}" --timestamp=none "$stage" >/dev/null
echo "подпись: ${identity:-ad-hoc}"

mkdir -p "$out"
rm -rf "$app"
mv "$stage" "$app"
echo "$app"
