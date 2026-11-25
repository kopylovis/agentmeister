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

# CLI agentmeister едет внутри приложения: приложение работает без отдельной установки CLI, а команда в терминале
# ставится ссылкой на него при первом запуске. Из git берутся только файлы репозитория, без __pycache__ и мусора.
cli=$stage/Contents/Resources/agentmeister
mkdir -p "$cli"
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  (cd "$root" && git ls-files -z bin libexec share VERSION | tar -c --null -T - -f -) | tar -x -C "$cli" -f -
else
  (cd "$root" && tar -c --exclude __pycache__ --exclude '*.pyc' --exclude .DS_Store -f - bin libexec share VERSION) \
    | tar -x -C "$cli" -f -
fi
[[ -x $cli/bin/agentmeister ]] || { echo "bundle.sh: CLI не скопировался в $cli" >&2; exit 1; }

# promptsill, строка состояния Claude Code, тоже едет внутри: ссылку ~/.local/bin/promptsill приложение ставит
# при первом запуске, если promptsill еще нигде нет. Версия закреплена, файл проверяется по sha256 и кэшируется.
promptsill_version=0.10.0
promptsill_sha256=af04564e9c2be3fc5259c9c758e64f5e26483596bb56700bd85c85213ca581e3
cached=$here/build/cache/promptsill-$promptsill_version
if [[ ! -f $cached/promptsill ]]; then
  mkdir -p "$cached"
  base=https://raw.githubusercontent.com/kopylovis/promptsill/v$promptsill_version
  curl -fsSL "$base/promptsill" -o "$cached/promptsill.part" && curl -fsSL "$base/LICENSE" -o "$cached/LICENSE" \
    || { echo "bundle.sh: не скачал promptsill $promptsill_version" >&2; exit 1; }
  [[ $(shasum -a 256 "$cached/promptsill.part" | cut -d' ' -f1) == "$promptsill_sha256" ]] \
    || { rm -f "$cached/promptsill.part"; echo "bundle.sh: promptsill $promptsill_version не сошелся по sha256" >&2; exit 1; }
  mv "$cached/promptsill.part" "$cached/promptsill"
fi
mkdir -p "$stage/Contents/Resources/promptsill"
install -m 755 "$cached/promptsill" "$stage/Contents/Resources/promptsill/promptsill"
cp "$cached/LICENSE" "$stage/Contents/Resources/promptsill/LICENSE"

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
  <key>NSAppleEventsUsageDescription</key><string>Agentmeister opens sessions in iTerm2 or Terminal tabs.</string>
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
# расширенные атрибуты (карантин, provenance) codesign не пропускает
xattr -cr "$stage"
sign=(codesign --force --sign "${identity:--}")
if [[ $identity == "Developer ID Application:"* ]]; then
  # для нотаризации: hardened runtime и метка времени. Apple Events нужны вкладкам iTerm2 и Terminal через osascript.
  entitlements=$tmp/entitlements.plist
  cat > "$entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENT
  sign+=(--options runtime --timestamp --entitlements "$entitlements")
else
  sign+=(--timestamp=none)
fi
"${sign[@]}" "$stage" >/dev/null
codesign --verify --strict "$stage"
echo "подпись: ${identity:-ad-hoc}"

mkdir -p "$out"
rm -rf "$app"
mv "$stage" "$app"
echo "$app"
