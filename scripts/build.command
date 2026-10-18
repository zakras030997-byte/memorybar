#!/bin/zsh
set -euo pipefail
mb_source="${0:A:h:h}"
mb_sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
# Prefer the SDK verified with the restored toolchain if it is available.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  mb_sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
mb_output="${mb_source}/build/Мониторинг RAM.app"
if [[ -e "$mb_output" ]]; then print 'Папка build уже содержит приложение. Сохраните или переместите её перед новой сборкой.'; exit 1; fi
mb_temp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/memorybar-build.XXXXXX")"
trap '/bin/rm -rf -- "$mb_temp"' EXIT
/usr/bin/xcrun clang -isysroot "$mb_sdk_path" -fobjc-arc -mmacosx-version-min=14.0 -c "$mb_source/Sources/Metrics.m" -o "$mb_temp/Metrics.o"
/usr/bin/xcrun swiftc -sdk "$mb_sdk_path" -module-cache-path "$mb_temp/cache" -target arm64-apple-macosx14.0 -O "$mb_source/Sources/MemoryBar.swift" "$mb_temp/Metrics.o" -framework AppKit -framework SwiftUI -framework Foundation -framework IOKit -o "$mb_temp/MemoryBar"
/bin/mkdir -p "$mb_output/Contents/MacOS" "$mb_output/Contents/Resources"
/bin/cp "$mb_source/Resources/Info.plist" "$mb_output/Contents/Info.plist"
/bin/cp "$mb_source/Resources/AppIcon.icns" "$mb_output/Contents/Resources/AppIcon.icns"
/bin/cp "$mb_temp/MemoryBar" "$mb_output/Contents/MacOS/MemoryBar"
/usr/bin/codesign --force --sign - "$mb_output"
/usr/bin/codesign --verify --deep --strict "$mb_output"
"$mb_output/Contents/MacOS/MemoryBar" --self-test
print "Собрано: $mb_output"
