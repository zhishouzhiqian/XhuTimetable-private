"""准备 iOS 组件检查素材；安全资源只生成到用户指定的本地输出，不进入源码。"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request
import zipfile

SDK_URL = "https://baichuan-sdk-bucket.oss-cn-hangzhou.aliyuncs.com/ios/AlibcTradeUltimateSDK_all_package_50018.zip"
SDK_SHA256 = "e5291469e34c8c1caf3949f2972320a63c7e03fcf5ce3d1bceca374ac0872a3e"
FRAMEWORKS = ("SecurityGuardSDK", "SGMain", "SGMiddleTier", "SGSecurityBody")
RESOURCE_NAMES = ("yw_1222.jpg", "yw_1222_mwua.jpg")


def resource_document(ipa: Path) -> dict:
    resources = {}
    with zipfile.ZipFile(ipa) as archive:
        for name in RESOURCE_NAMES:
            matches = [item for item in archive.infolist()
                       if item.filename.startswith("Payload/")
                       and len(item.filename.split("/")) == 3
                       and item.filename.endswith(".app/" + name)]
            if len(matches) != 1 or not 0 < matches[0].file_size <= 65536:
                raise ValueError("安全资源缺失、重复或过大。")
            resources[name] = base64.b64encode(archive.read(matches[0])).decode("ascii")
    return {"format": "campus-ios-component-resources", "version": 1, "resources": resources}


def extract_sdk(sdk: Path, output: Path) -> None:
    if hashlib.sha256(sdk.read_bytes()).hexdigest() != SDK_SHA256:
        raise ValueError("候选 SDK 校验失败。")
    output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(sdk) as archive:
        for framework in FRAMEWORKS:
            prefix = f"AlibcTradeUltimateSDK_all_package_50018/Source/framework/securityGuard/{framework}.framework/"
            entries = [item for item in archive.infolist() if item.filename.startswith(prefix)]
            if not any(item.filename == prefix + framework for item in entries):
                raise ValueError("SDK 缺少所需 framework。")
            for item in entries:
                relative = Path(item.filename[len(prefix):])
                if relative.is_absolute() or ".." in relative.parts or "\\" in item.filename:
                    raise ValueError("SDK 路径无效。")
                if item.file_size > 100_000_000 or ((item.external_attr >> 16) & 0o170000) == 0o120000:
                    raise ValueError("SDK 包含不支持的文件。")
                target = output / (framework + ".framework") / relative
                if item.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(item) as source, target.open("wb") as destination:
                        shutil.copyfileobj(source, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--resources-output", type=Path)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--frameworks-output", type=Path)
    args = parser.parse_args()
    if args.ipa:
        if not args.resources_output:
            parser.error("需要指定本地资源输出文件。")
        args.resources_output.parent.mkdir(parents=True, exist_ok=True)
        args.resources_output.write_text(json.dumps(resource_document(args.ipa)), encoding="utf-8")
        print("本地检查资源已准备；未包含会话、授权码或订单数据。")
    if args.frameworks_output:
        sdk = args.sdk or args.frameworks_output.parent / "public-sdk.zip"
        if not sdk.exists():
            sdk.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(SDK_URL, timeout=60) as response, sdk.open("wb") as destination:
                shutil.copyfileobj(response, destination)
        extract_sdk(sdk, args.frameworks_output)
        print("候选 SDK 完整性校验及 framework 准备成功。")


if __name__ == "__main__":
    main()
