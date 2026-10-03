"""精简已验证的课表原配整合 IPA；只删明确的原校园资源，不修改任何保留文件。"""
import argparse
import copy
import hashlib
import json
import plistlib
import shutil
import struct
import zipfile
from pathlib import Path, PurePosixPath

from audit_campus_ios_ipa import macho_header

# SDK、默认配置、主程序、图标、Compose 资源与所有动态库始终保留。
UNUSED_BUNDLES = frozenset("""
AMap.bundle AMapNavi.bundle TCAIAssistant.bundle TCAIBookkeeping.bundle TCAINote.bundle
TCBusinessKit.bundle TCCourseSchedule.bundle TCMessage.bundle TCAccount.bundle TCUIKit.bundle
TCWDMall.bundle TCShareKit.bundle TCAudioPlayer.bundle TCAudioRecorder.bundle TCVideoPlayer.bundle
TCVoiceRecognizer.bundle AntMarkdown.bundle FluidMarkdown.bundle GKPhotoBrowser.bundle
TZImagePickerController.bundle TOCropViewControllerBundle.bundle MJRefresh.bundle
baidumobadsdk.bundle CSJAdSDK.bundle MSAdSDK.bundle OctAdSDK.bundle OctCore.bundle QuMengAdBundle.bundle
KSUAdDebugToolResource.bundle KSUBannerAdResource.bundle KSUConversionResource.bundle KSUDrawAdResource.bundle
KSUFeedAdResource.bundle KSUImagePlayerResource.bundle KSUInterstitialAdResource.bundle KSUNativeAdResources.bundle
KSUSplashAdResource.bundle KSUUIResource.bundle KSUVideoAdResource.bundle KSUVideoViewResource.bundle
SmartdigimktSDK.bundle
""".split())
UNUSED_FILES = {"tc_school_db.sqlite", "answer.zip", "iconfont.ttf", "DingTalk Sans.ttf", "Akrobat-Black.otf", "UJU-Bold.ttf", "UJU-Regular.ttf",
                 "TCPostTemplate.json", "RemoveMe", "home_loading.gif", "print_loading.webp",
                 "ubixCommonLoading.gif", "ubixLoading.webp", "mega_speech_microphone@3x.png"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def removal_reason(relative):
    parts = PurePosixPath(relative).parts
    if not parts:
        return None
    if parts[0] == "PlugIns":
        return "原校园通知与实时活动扩展"
    if parts[0] in UNUSED_BUNDLES:
        return "原校园业务界面、地图或广告素材"
    if parts[0] == "tabbar":
        return "原校园导航图片"
    if len(parts) == 1 and (parts[0] in UNUSED_FILES or parts[0].endswith((".pag", ".caf"))):
        return "原校园页面动画、音效、字体或业务数据"
    return None


def dependencies(data):
    # FAT 包保留所有架构原字节，仅解析 arm64 的加载命令。
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        fat64 = data[:4] == b"\xca\xfe\xba\xbf"
        count = struct.unpack_from(">I", data, 4)[0]
        stride = 32 if fat64 else 20
        if not 0 < count <= 32 or len(data) < 8 + count * stride:
            raise ValueError("FAT 架构表无效。")
        slices = []
        for index in range(count):
            pos = 8 + index * stride
            cpu = struct.unpack_from(">I", data, pos)[0]
            offset, size = struct.unpack_from(">QQ" if fat64 else ">II", data, pos + 8)
            if offset + size > len(data):
                raise ValueError("FAT 架构范围越界。")
            if cpu == 0x100000C:
                slices.append(data[offset:offset + size])
        if len(slices) != 1:
            raise ValueError("不能确定唯一 arm64 架构。")
        data = slices[0]
    header = macho_header(data)
    if header["cpu"] != "0x100000c" or header["declares_encryption"]:
        raise ValueError("需要未加密 arm64 载体。")
    result = []
    pos = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, pos)
        if command in (0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20):
            if size < 24:
                raise ValueError("动态库加载命令过短。")
            offset = struct.unpack_from("<I", data, pos + 8)[0]
            if not 24 <= offset < size:
                raise ValueError("动态库路径范围无效。")
            name = data[pos + offset:pos + size].split(b"\0", 1)[0].decode("utf-8")
            result.append(name)
        pos += size
    return result


def plan(source):
    names = source.namelist()
    if len(names) != len(set(names)):
        raise ValueError("IPA 存在重复条目。")
    for name in names:
        if name.startswith("/") or "\\" in name or ".." in PurePosixPath(name).parts:
            raise ValueError("IPA 条目路径无效。")
    plists = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
    if len(plists) != 1:
        raise ValueError("主应用不唯一。")
    metadata = plistlib.loads(source.read(plists[0]))
    app = plists[0].rsplit("/", 1)[0] + "/"
    executable = metadata.get("CFBundleExecutable", "")
    host = metadata.get("CampusTimetableHost", {})
    if (metadata.get("CFBundleIdentifier") != "com.tmall.campus4iphone" or
            not isinstance(host, dict) or host.get("version") != 2 or host.get("paymentEnabled") is not True or
            not executable or "/" in executable or "\\" in executable or executable in (".", "..")):
        raise ValueError("需要已验证的课表原配付款整合载体。")
    main, library = app + executable, app + "CampusOriginalProbe.dylib"
    library_data = source.read(library)
    manifest = metadata.get("CampusOriginalProbe", {})
    if (b"xhu-campus-timetable-host:2\0" not in library_data or
            manifest.get("librarySHA256") != digest(library_data)):
        raise ValueError("整合库与原配清单不一致。")
    for resource, entry in manifest.get("resources", {}).items():
        if "/" in resource or "\\" in resource or not resource.startswith("yw_"):
            raise ValueError("安全资源清单名称无效。")
        if digest(source.read(app + resource)) != entry.get("sha256"):
            raise ValueError("原配安全资源不一致。")
    if not {"yw_1222.jpg", "yw_1222_mwua.jpg"} <= set(manifest.get("resources", {})):
        raise ValueError("缺少原配安全资源清单。")
    removed = {n: removal_reason(n[len(app):]) for n in names if n.startswith(app)}
    removed = {n: reason for n, reason in removed.items() if reason}
    retained = set(names) - set(removed)
    if not any(n.startswith(app + "compose-resources/") for n in retained):
        raise ValueError("缺少课表共享资源。")
    # 校验加载闭包；资源策略不得删除任何递归加载依赖。
    pending, checked = [main, library], set()
    while pending:
        name = pending.pop()
        if name in checked:
            continue
        if name not in retained:
            raise ValueError("精简会删除真实加载依赖。")
        checked.add(name)
        for dependency in dependencies(source.read(name)):
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency.startswith("@rpath/"):
                target = app + "Frameworks/" + dependency[len("@rpath/"):]
            elif dependency.startswith("@executable_path/"):
                target = app + dependency[len("@executable_path/"):]
            elif dependency.startswith("@loader_path/"):
                target = name.rsplit("/", 1)[0] + "/" + dependency[len("@loader_path/"):]
            else:
                raise ValueError("不能确定本地动态依赖的解析路径。")
            if target not in names and dependency.startswith("@rpath/libswift"):
                # 与已验证载体一致：未嵌入的 Swift 系统运行库由 iOS 提供。
                continue
            pending.append(target)
    return app, removed, retained, sorted(checked)


def prepare(ipa, output):
    if output.exists() or output.resolve() == ipa.resolve():
        raise ValueError("输出必须是新的独立文件。")
    with zipfile.ZipFile(ipa) as source:
        app, removed, retained, linked = plan(source)
        output.parent.mkdir(parents=True, exist_ok=True)
        created = False
        try:
            with output.open("xb") as stream:
                created = True
                with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as target:
                    for item in source.infolist():
                        if item.filename in removed:
                            continue
                        # 写 ZIP 会更新 header_offset，不能复用输入档案的 ZipInfo 实例。
                        with source.open(item) as original, target.open(copy.copy(item), "w") as copied:
                            shutil.copyfileobj(original, copied)
            with zipfile.ZipFile(output) as target:
                if target.testzip() is not None or set(target.namelist()) != retained:
                    raise ValueError("精简 IPA 完整性或条目集合不一致。")
                for name in retained:
                    if digest(source.read(name)) != digest(target.read(name)):
                        raise ValueError("保留文件发生变化。")
                plan(target)
        except Exception:
            if created:
                output.unlink(missing_ok=True)
            raise
        groups = {}
        for name, reason in removed.items():
            root = name[len(app):].split("/")[0]
            group = groups.setdefault(root, {"reason": reason, "entries": 0, "bytes": 0})
            group["entries"] += 1
            group["bytes"] += source.getinfo(name).file_size
        return {"format": "xhu-campus-timetable-resource-slim", "version": 1,
                "sourceBytes": ipa.stat().st_size, "outputBytes": output.stat().st_size,
                "savedBytes": ipa.stat().st_size - output.stat().st_size,
                "removedEntries": len(removed), "removedUncompressedBytes": sum(g["bytes"] for g in groups.values()),
                "retainedEntries": len(retained), "linkedImages": len(linked), "retainedFilesVerified": True,
                "removedGroups": groups,
                "note": "仅资源精简；保留主程序、所有动态库、Compose、图标及安全资源。保留文件逐字节核对，业务仍需同环境真机验收。"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.report and (args.report.exists() or args.report.resolve() in (args.ipa.resolve(), args.output.resolve())):
        parser.error("报告必须是新的独立文件。")
    report = prepare(args.ipa, args.output)
    content = json.dumps(report, ensure_ascii=False, indent=2)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(content + "\n", encoding="utf-8")
    print(content)


if __name__ == "__main__":
    main()
