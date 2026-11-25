#!/bin/bash
# Релиз Agentmeister для других маков. Release-сборка, CLI agentmeister внутри приложения, подпись Developer ID
# с hardened runtime, нотаризация приложения, DMG со ссылкой на Applications, подпись и нотаризация DMG.
#
#   ./release.sh            результат в app/build/release/Agentmeister-<версия>.dmg, сборка для Apple Silicon и Intel
#
# Подпись берется из AGENTMEISTER_SIGN или первой Developer ID Application из связки ключей. Нотаризация идет через
# профиль notarytool из AGENTMEISTER_NOTARY_PROFILE, по умолчанию tossling-notary (ключ App Store Connect API той же
# команды разработчика). Свой профиль создает
#   xcrun notarytool store-credentials agentmeister-notary --key AuthKey.p8 --key-id <id> --issuer <issuer>
# Нужна прямая сеть и связка ключей, поэтому из сессии через proxy скрипт запускает host-run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
version=$(cat "$root/VERSION")
profile=${AGENTMEISTER_NOTARY_PROFILE:-tossling-notary}
identity=${AGENTMEISTER_SIGN:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1 || true)}

die() { echo "release.sh: $*" >&2; exit 1; }
[[ $identity == "Developer ID Application:"* ]] || die "нет сертификата Developer ID Application в связке ключей"
# в DMG идет закоммиченное: bundle.sh берет файлы из рабочей копии, и незакоммиченная правка уехала бы подписанной
dirty=$(git -C "$root" status --porcelain -- bin libexec share VERSION app/Sources app/Package.swift app/Package.resolved \
  app/bundle.sh app/release.sh app/sparkle-public-key)
[[ -z $dirty ]] || die "есть незакоммиченные изменения, сначала закоммить их:
$dirty"
# Sparkle: sign_update подписывает DMG для appcast секретным ключом из связки (generate_keys --account agentmeister).
# Инструменты из архива Sparkle той же версии, что в Package.swift, архив сверяется по sha256.
sparkle_version=2.10.0
sparkle_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
sparkle_tools=$here/build/cache/sparkle-$sparkle_version
pubkey=$(tr -d ' \n' < "$here/sparkle-public-key" 2>/dev/null || true)
if [[ -n $pubkey ]]; then
  if [[ ! -x $sparkle_tools/bin/sign_update ]]; then
    mkdir -p "$sparkle_tools"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
      -o "$sparkle_tools/sparkle.tar.xz" || die "не скачал Sparkle $sparkle_version"
    [[ $(shasum -a 256 "$sparkle_tools/sparkle.tar.xz" | cut -d' ' -f1) == "$sparkle_sha256" ]] \
      || { rm -f "$sparkle_tools/sparkle.tar.xz"; die "архив Sparkle не сошелся по sha256"; }
    tar -xf "$sparkle_tools/sparkle.tar.xz" -C "$sparkle_tools" bin LICENSE
    rm -f "$sparkle_tools/sparkle.tar.xz"
  fi
  # ключ в связке должен совпадать с тем, что встанет в приложение, иначе обновление не примут
  [[ $("$sparkle_tools/bin/generate_keys" --account agentmeister -p 2>/dev/null | tr -d ' \n') == "$pubkey" ]] \
    || die "в связке ключей нет ключа Sparkle agentmeister с публичной частью из app/sparkle-public-key"
fi
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
  || die "профиль notarytool $profile не читается. Обычно Mac заблокирован и связка ключей его прячет, разблокируй и запусти снова"

# ответ notarytool целиком в лог, в вывод последние строки; не Accepted, тогда и журнал Apple с причиной
submit() {
  local result id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait 2>&1) || true
  echo "$result" | tail -3
  if ! grep -q "status: Accepted" <<<"$result"; then
    id=$(sed -n 's/^ *id: *\([0-9a-f-]*\).*/\1/p' <<<"$result" | head -1)
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$profile" 2>&1 | tail -40
    die "нотаризация $(basename "$1") не прошла"
  fi
}

cd "$here"
echo "сборка release для arm64 и x86_64…"
arch=(--arch arm64 --arch x86_64)
swift build -c release "${arch[@]}" 2>&1 | tail -1
binary=$(swift build -c release "${arch[@]}" --show-bin-path)/Agentmeister
archs=$(lipo -archs "$binary")
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || die "в $binary нет обеих архитектур: $archs"
# все собирается во временную папку и встает на место только целиком: после сбоя не остается DMG, похожего на готовый
final=$here/build/release
out=$here/build/release.partial
rm -rf "$out"
mkdir -p "$out"
cleanup() { rm -rf "$out" "${stage:-}"; }
trap cleanup EXIT
AGENTMEISTER_SIGN="$identity" ./bundle.sh "$binary" "$out" >/dev/null
app=$out/Agentmeister.app
codesign --verify --strict --deep "$app"

echo "нотаризация приложения, это несколько минут…"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
submit "$out/notarize.zip"
rm -f "$out/notarize.zip"
xcrun stapler staple "$app" >/dev/null
spctl --assess --type execute "$app"

dmg=$out/Agentmeister-$version.dmg
stage=$(mktemp -d)
ditto "$app" "$stage/Agentmeister.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Agentmeister -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --force --sign "$identity" --timestamp "$dmg"
echo "нотаризация DMG…"
submit "$dmg"
xcrun stapler staple "$dmg" >/dev/null
spctl --assess --type open --context context:primary-signature "$dmg"
if [[ -n $pubkey ]]; then
  # appcast для Sparkle: одна запись, файл уходит в релиз на GitHub рядом с DMG, SUFeedURL смотрит на latest
  build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
  signed=$("$sparkle_tools/bin/sign_update" --account agentmeister "$dmg")
  [[ $signed == *edSignature=* ]] || die "sign_update не подписал DMG"
  cat > "$out/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agentmeister</title>
    <link>https://github.com/kopylovis/agentmeister</link>
    <item>
      <title>Agentmeister $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/kopylovis/agentmeister/releases/tag/v$version</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/kopylovis/agentmeister/releases/download/v$version/Agentmeister-$version.dmg" $signed type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
fi
rm -rf "$final"
mv "$out" "$final"
echo "$final/Agentmeister-$version.dmg"
if [[ -f $final/appcast.xml ]]; then echo "$final/appcast.xml"; fi
