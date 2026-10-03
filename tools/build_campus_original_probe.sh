#!/usr/bin/env bash
# 只构建本地诊断库；不下载原 IPA，不链接其它版本安全 SDK，不修改课表构建。
set -euo pipefail
cd "$(dirname "$0")/.."
output=build/ios-original-probe
mkdir -p "$output"
python3 -m unittest discover -s tools -p 'test_prepare_campus_original_probe.py'
xcrun --sdk macosx clang -fobjc-arc -fblocks -DCAMPUS_ORIGINAL_PROBE_TEST=1 \
  tools/ios-original-probe/OriginalProbe.m tools/ios-original-probe/OriginalNetworkProbe.m \
  tools/ios-original-probe/OriginalProbeTests.m tools/ios-original-probe/OriginalNetworkProbeTests.m \
  -framework Foundation -o "$output/native-tests"
"$output/native-tests"
xcrun --sdk iphoneos clang -fobjc-arc -fblocks -fvisibility=hidden -dynamiclib \
  -target arm64-apple-ios16.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -install_name '@executable_path/CampusOriginalProbe.dylib' \
  tools/ios-original-probe/OriginalProbe.m tools/ios-original-probe/OriginalNetworkProbe.m \
  -framework Foundation -framework UIKit \
  -o "$output/CampusOriginalProbe.dylib"
xcrun nm -gU "$output/CampusOriginalProbe.dylib" > "$output/exports.txt"
grep -q ' _CampusOriginalProbeMain$' "$output/exports.txt"
echo '原配诊断库已生成；需在本地原 IPA 副本中打包并递归重签。'
