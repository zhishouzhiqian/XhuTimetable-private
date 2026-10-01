#!/usr/bin/env bash
# 只编译 UIKit 检查宿主和候选 SDK；不会运行 Gradle、Kotlin/Native 或课表扩展。
set -euo pipefail
cd "$(dirname "$0")/.."

output=build/ios-component-probe
frameworks=build/campus-ios-probe/frameworks
app="$output/Payload/CampusComponentCheck.app"
mkdir -p "$app" "$output/logs"
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"

# 先用桩组件验证分支、完整性阻断和报告脱敏；不链接或执行真实安全 SDK。
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wno-incomplete-implementation \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -F "$frameworks" \
  -I iosApp/iosApp -I tools/ios-component-probe -DCAMPUS_COMPONENT_PROBE=1 \
  -DCAMPUS_COMPONENT_CAPTURE_SDK_ERRORS=1 -DCAMPUS_COMPONENT_TRACE_FILES=1 \
  tools/ios-component-probe/ProbeTests.m iosApp/iosApp/CampusComponentProbe.m \
  tools/ios-component-probe/ProbeResourceTrace.m \
  -framework Foundation -o "$output/probe-tests"
"$output/probe-tests"

xcrun --sdk iphoneos clang -fobjc-arc -fblocks -target arm64-apple-ios16.0 \
  -isysroot "$sdk_path" -F "$frameworks" -DCAMPUS_COMPONENT_PROBE=1 -DCAMPUS_COMPONENT_CAPTURE_SDK_ERRORS=1 \
  -I tools/ios-component-probe -DCAMPUS_COMPONENT_TRACE_FILES=1 \
  -c iosApp/iosApp/CampusComponentProbe.m -o "$output/CampusComponentProbe.o"

xcrun --sdk iphoneos clang -fobjc-arc -fblocks -target arm64-apple-ios16.0 \
  -isysroot "$sdk_path" -c tools/ios-component-probe/ProbeResourceTrace.m -o "$output/ProbeResourceTrace.o"

xcrun --sdk iphoneos swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-ios16.0 -sdk "$sdk_path" -module-name CampusComponentCheck \
  -import-objc-header iosApp/iosApp/CampusComponentProbe.h \
  iosApp/iosApp/LaundryComponentCheckViewController.swift \
  tools/ios-component-probe/ProbeAppDelegate.swift "$output/CampusComponentProbe.o" "$output/ProbeResourceTrace.o" \
  -F "$frameworks" -Xlinker -ObjC \
  -framework UIKit -framework Foundation -framework UniformTypeIdentifiers \
  -framework CryptoKit -framework SecurityGuardSDK -framework SGMain \
  -framework SGMiddleTier -framework SGSecurityBody \
  -framework Security -framework SystemConfiguration -framework CoreTelephony \
  -framework CoreMotion -framework WebKit -lc++ -lz -lresolv \
  -Xlinker -rpath -Xlinker /usr/lib/swift -o "$app/CampusComponentCheck"

python3 - <<'PY'
from pathlib import Path
import plistlib
import subprocess

app = Path('build/ios-component-probe/Payload/CampusComponentCheck.app')
version = subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], text=True).strip()
revision = subprocess.check_output(['git', 'rev-parse', '--short=7', 'HEAD'], text=True).strip()
info = {
    'CFBundleIdentifier': 'vip.mystery0.xhu.timetable.CampusComponentCheck',
    'CFBundleName': 'CampusComponentCheck', 'CFBundleDisplayName': '洗衣组件检查',
    'CFBundleExecutable': 'CampusComponentCheck', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': version, 'CFBundleShortVersionString': '1.0',
    'CampusProbeRevision': revision,
    'CFBundleDevelopmentRegion': 'zh_CN', 'CFBundleSupportedPlatforms': ['iPhoneOS'],
    'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1, 2], 'LSRequiresIPhoneOS': True,
    'UIRequiredDeviceCapabilities': ['arm64'], 'UILaunchScreen': {},
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait',
        'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
}
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
PY

ditto -c -k --sequesterRsrc --keepParent "$output/Payload" "$output/CampusComponentCheck-unsigned.ipa"
python3 - <<'PY'
import zipfile
with zipfile.ZipFile('build/ios-component-probe/CampusComponentCheck-unsigned.ipa') as archive:
    assert 'Payload/CampusComponentCheck.app/Info.plist' in archive.namelist()
    assert 'Payload/CampusComponentCheck.app/CampusComponentCheck' in archive.namelist()
    assert not any(name.endswith(('.jpg', '.json')) for name in archive.namelist()), '不得打包导入的安全资源'
    assert archive.testzip() is None
print('轻量检查 IPA 已打包。需要用户签名后进行真机验证。')
PY
