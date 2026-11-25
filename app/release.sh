#!/bin/bash
# Релиз Agentmeister для других маков. Release-сборка, CLI agentmeister внутри приложения, подпись Developer ID
# с hardened runtime, нотаризация приложения, DMG со ссылкой на Applications, подпись и нотаризация DMG.
#
#   ./release.sh            результат в app/build/release/Agentmeister-<версия>.dmg
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
echo "сборка release…"
swift build -c release 2>&1 | tail -1
out=$here/build/release
rm -rf "$out"
mkdir -p "$out"
AGENTMEISTER_SIGN="$identity" ./bundle.sh "" "$out" >/dev/null
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
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Agentmeister.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Agentmeister -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --force --sign "$identity" --timestamp "$dmg"
echo "нотаризация DMG…"
submit "$dmg"
xcrun stapler staple "$dmg" >/dev/null
spctl --assess --type open --context context:primary-signature "$dmg"
echo "$dmg"
