"""从已拆解的 APK 中提取安全组件和 MTOP 的引用闭包；产物只写 build。"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

def select_classes(sources):
    classes = {}
    texts = {}
    for directory in sources:
        for file in directory.rglob("*.smali"):
            name = "L" + file.relative_to(directory).as_posix()[:-6] + ";"
            classes[name] = file
    roots = {name for name in classes if name.startswith((
        "Lcom/alibaba/wireless/security/", "Lcom/taobao/wireless/security/",
        "Lcom/ut/device/", "Lcom/ta/utdid2/"))}
    roots.update("L" + name + ";" for name in (
        "mtopsdk/security/InnerSignImpl", "mtopsdk/mtop/global/MtopConfig",
        "mtopsdk/common/util/TBSdkLog", "mtopsdk/mtop/protocol/converter/impl/InnerNetworkConverter"))
    selected = set()
    pending = list(roots)
    while pending:
        name = pending.pop()
        if name in selected or name not in classes:
            continue
        selected.add(name)
        text = classes[name].read_text(encoding="utf-8")
        refs = set(re.findall(r"L[\w/$-]+;", text))
        # 反射加载的完整 Java 类名也纳入闭包。
        for value in re.findall(r'const-string(?:/jumbo)?[^\n]*, "([\w.$]+)"', text):
            refs.add("L" + value.replace(".", "/") + ";")
        pending.extend(refs - selected)
    return classes, selected

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk",type=Path,required=True)
    parser.add_argument("--work",type=Path,default=Path("build/campus-slim"))
    parser.add_argument("--tools",type=Path,default=Path("build/campus-slim-tools"))
    args=parser.parse_args()
    args.work.mkdir(parents=True,exist_ok=True)
    cp=str(args.tools / "*")
    sources=[]
    with ZipFile(args.apk) as apk:
        for name in apk.namelist():
            if re.fullmatch(r"classes[0-9]*\.dex",name):
                dex=args.work/name
                original=apk.read(name)
                if dex.exists() and hashlib.sha256(dex.read_bytes()).digest()!=hashlib.sha256(original).digest():
                    raise ValueError("拆解缓存与输入 APK 不同，请指定新的 --work 目录")
                if not dex.exists(): dex.write_bytes(original)
                directory=args.work/name[:-4]
                if not directory.exists():
                    subprocess.run(["java","-Xmx2g","-cp",cp,"org.jf.baksmali.Main","d",str(dex),"-o",str(directory),"-j","4"],check=True)
                sources.append(directory)
        classes, selected=select_classes(sources)
        import struct
        expected=sum(struct.unpack_from("<I",apk.read(name),96)[0] for name in apk.namelist() if re.fullmatch(r"classes[0-9]*\.dex",name))
        if len(classes)!=expected: raise ValueError("拆解文件不完整，拒绝生成组件")
        if "Lmtopsdk/security/InnerSignImpl;" not in selected: raise ValueError("缺少签名入口")
        import tempfile
        dex_dir=Path(tempfile.mkdtemp(prefix="dex-",dir=args.work))
        selection=args.work/"classes.txt"
        selection.write_text("\n".join(sorted(selected)),encoding="utf-8")
        subprocess.run(["javac","-encoding","UTF-8","-cp",cp,"-d",str(args.tools),"tools/WriteSelectedDex.java"],check=True)
        import os
        subprocess.run(["java","-Xmx3g","-cp",str(args.tools)+os.pathsep+cp,"WriteSelectedDex",str(selection),str(dex_dir),
                        *[str(args.work/(directory.name+".dex")) for directory in sources]],check=True)
        runtime=args.work/"campus-runtime-slim.apk"
        with ZipFile(runtime,"w",compression=ZIP_DEFLATED,compresslevel=9) as out:
            for dex in dex_dir.glob("*.dex"): out.write(dex,dex.name)
            for name in apk.namelist():
                if name in ("AndroidManifest.xml","resources.arsc") or name.startswith("res/drawable/yw_") or re.fullmatch(r"META-INF/[^/]+\.(RSA|DSA|EC|SF|MF)",name):
                    out.writestr(name,apk.read(name))
        report={"input_bytes":args.apk.stat().st_size,"output_bytes":runtime.stat().st_size,
                "input_classes":len(classes),"selected_classes":len(selected),"sha256":hashlib.sha256(runtime.read_bytes()).hexdigest()}
        (args.work/"report.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
        (args.work/"classes.txt").write_text("\n".join(sorted(selected)),encoding="utf-8")
        print(json.dumps(report))
if __name__ == "__main__": main()
