"""仅生成 Android debug 所需的本机组件及公开配置；不复制 HAR 身份或会话。"""
import argparse
import json
import hashlib
import shutil
from pathlib import Path
from urllib.parse import urlsplit, unquote_plus
from zipfile import ZipFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--har', type=Path, help='仅在首次生成公开配置时需要')
    parser.add_argument('--runtime', type=Path, required=True, help='已完成离线诊断的精简组件归档')
    args = parser.parse_args()
    output = Path(__file__).resolve().parents[1] / 'androidApp/build/generated/tmallDebug'
    assets = output / 'assets'
    assets.mkdir(parents=True, exist_ok=True)
    if args.har:
        entries = json.loads(args.har.read_text(encoding='utf-8-sig'))['log']['entries']
        request = next(e['request'] for e in entries if urlsplit(e['request']['url']).path ==
                       '/gw/mtop.tmall.campus.guide.advertising.config.list/1.0/')
        headers = {h['name'].lower(): h['value'] for h in request['headers']}
        public = {k: unquote_plus(headers[v]) for k, v in {
            'appKey': 'x-appkey', 'pv': 'x-pv', 'ttid': 'x-ttid',
            'x-features': 'x-features', 'extdata': 'x-extdata'}.items()}
        (assets / 'tmall-public.json').write_text(json.dumps(public), encoding='utf-8')
    elif not (assets / 'tmall-public.json').exists():
        raise ValueError('首次生成需要 --har 提供公开配置')
    with ZipFile(args.runtime) as runtime_zip:
        if any(n.startswith(('assets/', 'lib/')) for n in runtime_zip.namelist()):
            raise ValueError('组件归档仍含 App 资产或重复原生库')
        if 'classes.dex' not in runtime_zip.namelist():
            raise ValueError('组件归档缺少代码')
    with ZipFile(args.apk) as apk:
        names = [n for n in apk.namelist() if n.startswith('lib/arm64-v8a/libsg') and n.endswith('.so')]
        if len(names) != 4:
            raise ValueError('仅支持已核对的 5.7.0 组件布局')
        for name in names:
            dest = output / 'jniLibs' / Path(name).relative_to('lib')
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(apk.read(name))
    # 仅携带经过引用裁剪及离线诊断的组件归档，不打包整个官方 APK。
    runtime = assets / 'campus-runtime.apk'
    shutil.copyfile(args.runtime, runtime)
    (assets / 'campus-runtime.sha256').write_text(
        hashlib.sha256(runtime.read_bytes()).hexdigest(), encoding='ascii')
    print('已生成 debug 组件和公开配置，未复制抓包会话。')


if __name__ == '__main__':
    main()
