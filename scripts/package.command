#!/bin/zsh
set -euo pipefail
mb_root="${0:A:h:h}"
mb_app="$mb_root/build/Мониторинг Mac.app"
mb_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mb_app/Contents/Info.plist")
mb_output="$mb_root/dist/MemoryBar-${mb_version}-macOS-arm64.pkg"
[[ ! -e "$mb_output" ]] || { print 'Установщик уже существует; сохраните предыдущий результат.'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$mb_app"
"$mb_app/Contents/MacOS/MemoryBar" --self-test
mb_temp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/memorybar-package.XXXXXX")
trap '/bin/rm -rf -- "$mb_temp"' EXIT
/bin/mkdir -p "$mb_root/dist" "$mb_temp/root/Applications"
/usr/bin/ditto "$mb_app" "$mb_temp/root/Applications/Мониторинг Mac.app"
/usr/bin/pkgbuild --analyze --root "$mb_temp/root" "$mb_temp/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$mb_temp/components.plist"
/usr/bin/pkgbuild --root "$mb_temp/root" --component-plist "$mb_temp/components.plist" --identifier ai.anodhas.MemoryBar.installer --version "$mb_version" --install-location / --ownership recommended "$mb_output"
(cd "$mb_root/dist" && /usr/bin/shasum -a 256 "${mb_output:t}" > "${mb_output:t}.sha256")
print "Установщик: $mb_output"
