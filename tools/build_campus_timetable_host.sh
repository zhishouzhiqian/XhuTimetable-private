#!/usr/bin/env bash
# 手动构建课表原配整合库；原校园 IPA 始终留在用户电脑。
set -euo pipefail
cd "$(dirname "$0")/.."
output=build/ios-timetable-host
mkdir -p "$output/objects" "$output/resources"
python3 -m unittest discover -s tools -p 'test_prepare_campus_timetable_host.py'
bash tools/build_campus_original_probe.sh
bash tools/test_campus_timetable_linker.sh
xcrun --sdk macosx clang -fobjc-arc -fblocks \
  tools/ios-timetable-host/CampusTimetableModels.m tools/ios-timetable-host/CampusTimetableModelTests.m \
  -framework Foundation -framework CoreFoundation -o "$output/model-tests"
"$output/model-tests"
xcrun --sdk macosx clang -fobjc-arc -fblocks \
  tools/ios-timetable-host/CampusTimetableClient.m tools/ios-timetable-host/CampusTimetableClientTests.m \
  -framework Foundation -o "$output/client-tests"
"$output/client-tests"
# Compose 的正式同步任务负责收集所有依赖资源，避免只复制本模块的图片。
export BUILT_PRODUCTS_DIR="$PWD/$output"
export UNLOCALIZED_RESOURCES_FOLDER_PATH=resources
export PLATFORM_NAME=iphoneos
export ARCHS=arm64
export ENABLE_USER_SCRIPT_SANDBOXING=NO
./gradlew --configure-on-demand composeApp:exportLibraryDefinitions \
  composeApp:linkDebugFrameworkIosArm64 composeApp:syncComposeResourcesForIos --stacktrace
framework=composeApp/build/bin/iosArm64/debugFramework
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
sources=(tools/ios-original-probe/OriginalProbe.m tools/ios-original-probe/OriginalNetworkProbe.m \
  tools/ios-original-probe/OriginalDeviceProbe.m tools/ios-original-probe/OriginalLoginProbe.m \
  tools/ios-original-probe/OriginalAuthorizationView.m tools/ios-original-probe/OriginalReadResultsView.m \
  tools/ios-timetable-host/CampusTimetableClient.m tools/ios-timetable-host/CampusTimetableModels.m)
objects=()
for source in "${sources[@]}"; do
  object="$output/objects/$(basename "${source%.m}").o"
  xcrun --sdk iphoneos clang -c -fobjc-arc -fblocks -fvisibility=hidden -DCAMPUS_TIMETABLE_HOST=1 \
    -target arm64-apple-ios16.0 -isysroot "$sdk" "$source" -o "$object"
  objects+=("$object")
done
# Swift 导入生成的 ComposeApp 头文件，编译期同时检查跨语言协议与参数名称。
xcrun --sdk iphoneos swiftc -emit-library -module-name XhuCampusTimetableHost \
  -target arm64-apple-ios16.0 -sdk "$sdk" -F "$framework" -framework ComposeApp \
  -import-objc-header tools/ios-timetable-host/CampusTimetableClient.h \
  tools/ios-timetable-host/XhuCampusTimetableHost.swift \
  iosApp/iosApp/LaundryNativeUi.swift iosApp/iosApp/LaundryAuthorizationViewController.swift \
  iosApp/iosApp/LaundryQrScannerViewController.swift "${objects[@]}" \
  -Xlinker -install_name -Xlinker '@executable_path/CampusOriginalProbe.dylib' -Xlinker -ObjC \
  -Xlinker -dead_strip -Xlinker -exported_symbols_list -Xlinker tools/ios-timetable-host/exports.list \
  -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework UIKit \
  -framework WebKit -framework AVFoundation -framework Metal -framework MetalKit \
  -framework QuartzCore -framework CoreText -framework Security -framework SystemConfiguration \
  -framework ImageIO -framework CoreVideo -framework CoreMedia -framework Accelerate -framework OpenGLES \
  -Xlinker -map -Xlinker "$output/link-map.txt" \
  -lc++ -lsqlite3 -lz -o "$output/CampusOriginalProbe.dylib"
xcrun nm -gU "$output/CampusOriginalProbe.dylib" > "$output/exports.txt"
grep -q ' _CampusOriginalProbeMain$' "$output/exports.txt"
# 导出白名单也是保留根：SDK 包装函数不作为动态库公开入口，真实调用依赖仍须解析。
awk '{print $NF}' "$output/exports.txt" | LC_ALL=C sort > "$output/export-names.txt"
LC_ALL=C sort tools/ios-timetable-host/exports.list > "$output/expected-export-names.txt"
diff -u "$output/expected-export-names.txt" "$output/export-names.txt"
xcrun nm -u "$output/CampusOriginalProbe.dylib" > "$output/imports.txt"
# 保留链接图，若还有真实可达的不兼容符号，可从同一次构建定位引用来源。
# 打包器只接受带校验清单的课表整合产物，防止误用旧诊断库。
python3 tools/prepare_campus_timetable_host.py --create-artifact "$output" --output "$output/XhuCampusTimetableHost.zip"
echo '课表原配整合产物已生成；下载 ZIP 后在本地与原 IPA 合成并递归重签。'
