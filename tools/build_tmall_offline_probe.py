"""构建无 INTERNET 权限的临时诊断 APK；私有组件仅写入忽略的 build 目录。"""

import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
from urllib.parse import unquote_plus, urlsplit
import zipfile

from tmall_request_contract import RequestSnapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--har", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--register", action="store_true", help="准备设备注册，不自动发送")
    parser.add_argument("--serial", default="emulator-5554")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = root / "build" / "tmall-contract-probe"
    # 每轮创建独立目录，避免覆盖其他探针、密钥或报告。
    output = output / secrets.token_hex(6)
    output.mkdir(parents=True)
    env = dict(os.environ)
    env["TMALL_PROBE_KEY_PASSWORD"] = secrets.token_urlsafe(32)

    def run(stage, command):
        result = subprocess.run([str(x) for x in command], env=env, capture_output=True, text=True)
        if result.returncode:
            # 构建参数不含真实凭据；仍不回显子进程消息以免意外泄露环境信息。
            raise RuntimeError("构建失败阶段：" + stage)

    sdk = args.sdk.resolve()
    versions = sorted((sdk / "build-tools").iterdir(), key=lambda p: tuple(
        int(x) for x in p.name.split(".") if x.isdigit()))
    build_tools = versions[-1]
    jars = sorted((sdk / "platforms").glob("*/android.jar"),
                  key=lambda p: int(p.parent.name.split("-")[-1].split(".")[0]))
    android_jar = jars[-1]
    with args.har.open(encoding="utf-8-sig") as stream:
        entries = json.load(stream)["log"]["entries"]
    selected = next(e for e in entries if urlsplit(e["request"]["url"]).path ==
                    "/gw/mtop.tmall.campus.guide.advertising.config.list/1.0/")
    # 只取应用公开配置，不取 UTDID、设备 ID、Cookie、签名或账号状态。
    headers = {h["name"].lower(): h["value"] for h in selected["request"]["headers"]}
    profile = {key: unquote_plus(headers[key])
               for key in ("x-appkey", "x-pv", "x-ttid", "x-features", "x-extdata")}
    utdid = base64.b64encode(secrets.token_bytes(18)).decode()
    data = {}
    if args.register:
        def prop(name):
            result = subprocess.run([str(sdk / "platform-tools" / "adb.exe"), "-s", args.serial,
                                     "shell", "getprop", name], capture_output=True, text=True, check=True)
            value = result.stdout.strip()
            if not value:
                raise RuntimeError("无法取得当前模拟器型号")
            return value
        data = {"new_device": "true", "device_global_id": utdid,
                "c0": prop("ro.product.brand"), "c1": prop("ro.product.model"),
                **{"c" + str(i): "" for i in range(2, 7)}}
    snapshot = RequestSnapshot.freeze(
        "mtop.sys.newDeviceId" if args.register else "mtop.tmall.campus.guide.advertising.config.list", data,
        timestamp=str(int(time.time())), app_key=profile["x-appkey"],
        protocol_version=profile["x-pv"], ttid=profile["x-ttid"],
        features=profile["x-features"], extdata=profile["x-extdata"],
        utdid=utdid, biz_id="4099" if args.register else None,
    )
    assets = output / "assets"
    assets.mkdir()
    (assets / "snapshot.json").write_text(json.dumps(dict(snapshot.sign_parameters())), encoding="utf-8")
    classes = output / "classes"
    classes.mkdir()
    source = root / "tools" / "tmall_probe"
    run("javac", ["javac", "-encoding", "UTF-8", "-source", "8", "-target", "8",
                  "-classpath", android_jar, "-d", classes, source / "ProbeActivity.java"])
    dex = output / "dex"
    dex.mkdir()
    run("d8", [build_tools / "d8.bat", "--min-api", "26", "--lib", android_jar,
               "--output", dex, *classes.rglob("*.class")])
    unsigned = output / "unsigned.apk"
    run("aapt", [build_tools / "aapt.exe", "package", "-f", "-M", source / "AndroidManifest.xml",
                 "-I", android_jar, "-A", assets, "-F", unsigned])
    with zipfile.ZipFile(unsigned, "a") as target, zipfile.ZipFile(args.apk) as original:
        target.write(dex / "classes.dex", "classes.dex")
        libs = [name for name in original.namelist()
                if name.startswith("lib/arm64-v8a/libsg") and name.endswith(".so")]
        if len(libs) != 4:
            raise RuntimeError("来源 APK 安全组件布局与已核对版本不同")
        for name in libs:
            target.writestr(name, original.read(name))
    aligned = output / "aligned.apk"
    run("zipalign", [build_tools / "zipalign.exe", "-f", "4", unsigned, aligned])
    key = output / "probe.jks"
    run("keytool", ["keytool", "-genkeypair", "-keystore", key, "-alias", "probe", "-keyalg", "RSA",
                    "-keysize", "2048", "-validity", "2", "-dname", "CN=Offline Diagnostic",
                    "-storepass:env", "TMALL_PROBE_KEY_PASSWORD",
                    "-keypass:env", "TMALL_PROBE_KEY_PASSWORD", "-noprompt"])
    signed = output / "probe.apk"
    run("apksigner", [build_tools / "apksigner.bat", "sign", "--ks", key, "--ks-key-alias", "probe",
                      "--ks-pass", "env:TMALL_PROBE_KEY_PASSWORD", "--out", signed, aligned])
    key.unlink()  # 临时签名只用于本次诊断安装，不作为项目签名保留。
    run("verify", [build_tools / "apksigner.bat", "verify", signed])
    # 只返回产物路径，不返回快照或签名材料。
    print(str(signed))


if __name__ == "__main__":
    main()
