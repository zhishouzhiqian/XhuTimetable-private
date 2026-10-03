"""将课表整合构建与已核对的原校园 IPA 合成；不上传 IPA，不改动输入文件。"""
import argparse
import hashlib
import json
import plistlib
import shutil
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

import prepare_campus_original_probe as original

FORMAT = "xhu-campus-timetable-host"
LIBRARY = "CampusOriginalProbe.dylib"
MARKER = b"xhu-campus-timetable-host:1\x00"
MAX_LIBRARY = 512 * 1024 * 1024
MAX_RESOURCE = 64 * 1024 * 1024
MAX_TOTAL = 768 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def resource_name(name):
    path = PurePosixPath(name)
    if not name.startswith("resources/compose-resources/") or "\\" in name or "\x00" in name or any(
        part in ("", ".", "..") for part in name.split("/")
    ) or path.is_absolute() or str(path) != name:
        raise ValueError("资源路径越界或无效。")
    return name.removeprefix("resources/")


def create_artifact(directory, output):
    if output.exists():
        raise ValueError("输出必须是新的文件。")
    library = directory / LIBRARY
    if not 32 <= library.stat().st_size <= MAX_LIBRARY:
        raise ValueError("整合库大小无效。")
    content = library.read_bytes()
    if MARKER not in content:
        raise ValueError("缺少课表客户端标记，不能使用旧诊断库。")
    # 编译器与启动符号检查由构建脚本完成；清单绑定库和全部资源。
    files = {LIBRARY: content}
    root = directory / "resources" / "compose-resources"
    if not root.is_dir():
        raise ValueError("缺少 Compose 正式同步的资源目录。")
    for item in sorted(root.rglob("*")):
        if item.is_symlink():
            raise ValueError("资源不得为符号链接。")
        if item.is_file():
            name = item.relative_to(directory).as_posix()
            resource_name(name)
            if item.stat().st_size > MAX_RESOURCE:
                raise ValueError("单个资源过大。")
            files[name] = item.read_bytes()
    if len(files) < 2 or sum(map(len, files.values())) > MAX_TOTAL:
        raise ValueError("资源为空或整合产物过大。")
    manifest = {"format": FORMAT, "version": 1, "files": {
        name: {"bytes": len(data), "sha256": digest(data)} for name, data in files.items()
    }}
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("xb") as stream, zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as target:
        target.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False))
        for name, data in files.items():
            target.writestr(name, data)
    return {"format": FORMAT, "files": len(files)}


def read_artifact(artifact):
    with zipfile.ZipFile(artifact) as source:
        entries = source.infolist()
        names = [item.filename for item in entries]
        if len(names) != len(set(names)) or len(names) > 20000 or "manifest.json" not in names:
            raise ValueError("整合 ZIP 条目无效。")
        if source.getinfo("manifest.json").file_size > 4 * 1024 * 1024:
            raise ValueError("清单过大。")
        manifest = json.loads(source.read("manifest.json"))
        if manifest.get("format") != FORMAT or manifest.get("version") != 1 or not isinstance(manifest.get("files"), dict):
            raise ValueError("不是课表整合构建产物，不能使用旧诊断库。")
        expected = manifest["files"]
        if set(names) != set(expected) | {"manifest.json"} or LIBRARY not in expected or len(expected) < 2:
            raise ValueError("清单与库、资源不一致。")
        if sum(item.file_size for item in entries) > MAX_TOTAL:
            raise ValueError("整合 ZIP 解压后过大。")
        files = {}
        for name, descriptor in expected.items():
            if name != LIBRARY:
                resource_name(name)
            maximum = MAX_LIBRARY if name == LIBRARY else MAX_RESOURCE
            item = source.getinfo(name)
            if item.file_size > maximum or not isinstance(descriptor, dict) or descriptor.get("bytes") != item.file_size:
                raise ValueError("文件大小与清单不一致。")
            data = source.read(name)
            if digest(data) != descriptor.get("sha256"):
                raise ValueError("文件摘要与清单不一致。")
            files[name] = data
        if MARKER not in files[LIBRARY]:
            raise ValueError("整合库缺少课表客户端标记。")
        return files


def prepare(ipa, artifact, output):
    if output.exists() or output.resolve() in (ipa.resolve(), artifact.resolve()):
        raise ValueError("输出必须是新的独立文件。")
    files = read_artifact(artifact)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="xhu-campus-host-", dir=output.parent) as scratch:
        directory = Path(scratch)
        library = directory / LIBRARY
        library.write_bytes(files[LIBRARY])
        carrier = directory / "carrier.ipa"
        original.prepare(ipa, library, carrier, max_library_size=MAX_LIBRARY)
        with zipfile.ZipFile(carrier) as source:
            plist_name = next(name for name in source.namelist() if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist"))
            app = plist_name.rsplit("/", 1)[0]
            additions = {app + "/" + resource_name(name): data for name, data in files.items() if name != LIBRARY}
            if set(additions) & set(source.namelist()):
                raise ValueError("课表资源与原载体条目冲突。")
            metadata = plistlib.loads(source.read(plist_name))
            metadata["CFBundleDisplayName"] = "西瓜课表（校园整合测试）"
            metadata["NSCameraUsageDescription"] = "扫描校园洗衣机二维码，查看设备程序与状态。"
            metadata["CampusTimetableHost"] = {"version": 1, "artifactSHA256": digest(artifact.read_bytes()), "paymentEnabled": False}
            stream = output.open("xb")
            try:
                with stream, zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as target:
                    for item in source.infolist():
                        if item.filename == plist_name:
                            target.writestr(item, plistlib.dumps(metadata))
                        else:
                            with source.open(item) as original_file, target.open(item, "w") as copied:
                                shutil.copyfileobj(original_file, copied)
                    for name, data in additions.items():
                        target.writestr(name, data)
            except Exception:
                output.unlink(missing_ok=True)
                raise
    return {"format": FORMAT, "version": 1, "resources": len(files) - 1,
            "note": "未签名整合测试副本；保留原 SDK 载体，需递归重签。只支持登录、扫码与订单查询。"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--create-artifact", type=Path)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.create_artifact:
        result = create_artifact(args.create_artifact, args.output)
    elif args.ipa and args.artifact:
        result = prepare(args.ipa, args.artifact, args.output)
    else:
        parser.error("需要 --create-artifact，或同时指定 --ipa 和 --artifact。")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
