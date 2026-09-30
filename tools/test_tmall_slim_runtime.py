"""构建无 INTERNET 权限的内置组件诊断包；不访问真实账号或网络。"""
import argparse, base64, hashlib, json, os, secrets, shutil, subprocess, time
from pathlib import Path
from zipfile import ZipFile

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--runtime',type=Path,required=True)
    ap.add_argument('--sdk',type=Path,required=True)
    ap.add_argument('--package',default='vip.mystery0.xhu.timetable.slimprobe')
    args=ap.parse_args()
    root=Path(__file__).resolve().parents[1]
    output=root/'build'/('slim-probe-'+secrets.token_hex(4));output.mkdir()
    assets=output/'assets';assets.mkdir()
    shutil.copyfile(args.runtime,assets/'campus-runtime.apk')
    (assets/'campus-runtime.sha256').write_text(hashlib.sha256(args.runtime.read_bytes()).hexdigest())
    config=json.loads((root/'androidApp/build/generated/tmallDebug/assets/tmall-public.json').read_text())
    config.update(api='mtop.tmall.campus.guide.advertising.config.list',v='1.0',data='{}',t=str(int(time.time())),utdid=base64.b64encode(secrets.token_bytes(18)).decode())
    (assets/'snapshot.json').write_text(json.dumps(config))
    source=(root/'tools/tmall_probe/ProbeActivity.java').read_text(encoding='utf-8')
    source=source.replace('vip.mystery0.xhu.timetable.offlineprobe',args.package)
    source=source.replace('Context source = createPackageContext("com.tmall.campus.and",\n                    Context.CONTEXT_INCLUDE_CODE | Context.CONTEXT_IGNORE_SECURITY);\n                Context context = new ProbeContext(source, getApplicationContext());','Context source = BundledCampusRuntime.open(getApplicationContext());\n                Context context = source;')
    source=source.replace('stage = "generate_factors";','''stage = "login_risk_fields";
                Class<?> managerClass = loader.loadClass("com.alibaba.wireless.security.open.SecurityGuardManager");
                Object manager = managerClass.getMethod("getInstance", Context.class).invoke(null, context);
                Class<?> bodyClass = loader.loadClass("com.alibaba.wireless.security.open.securitybody.ISecurityBodyComponent");
                Object body = managerClass.getMethod("getInterface", Class.class).invoke(manager, bodyClass);
                String wua = (String) bodyClass.getMethod("getSecurityBodyDataEx", String.class, String.class,
                    String.class, HashMap.class, int.class, int.class).invoke(body, Long.toString(System.currentTimeMillis()), frozen.get("appKey"), "", null, 4, 0);
                report.put("login_wua_present", wua != null && !wua.isEmpty());
                stage = "generate_factors";''')
    (output/'ProbeActivity.java').write_text(source,encoding='utf-8')
    runtime=(root/'androidApp/src/debug/java/vip/mystery0/xhu/timetable/laundry/BundledCampusRuntime.java').read_text(encoding='utf-8').replace('package vip.mystery0.xhu.timetable.laundry;','package '+args.package+';')
    (output/'BundledCampusRuntime.java').write_text(runtime,encoding='utf-8')
    sdk=args.sdk.resolve();bt=sdk/'build-tools/37.0.0'
    jar=sorted((sdk/'platforms').glob('*/android.jar'))[-1]
    env=dict(os.environ);env['PROBE_PASS']=secrets.token_urlsafe(32)
    def run(cmd):
        result=subprocess.run([str(x) for x in cmd],env=env,capture_output=True)
        if result.returncode: raise RuntimeError('诊断构建失败：'+str(cmd[0])+':'+result.stderr.decode(errors='replace')[:1500])
    classes=output/'classes';classes.mkdir();dex=output/'dex';dex.mkdir()
    run(['javac','-encoding','UTF-8','-source','8','-target','8','-cp',jar,'-d',classes,output/'ProbeActivity.java',output/'BundledCampusRuntime.java'])
    run([bt/'d8.bat','--min-api','26','--lib',jar,'--output',dex,*classes.rglob('*.class')])
    (output/'AndroidManifest.xml').write_text((root/'tools/tmall_probe/AndroidManifest.xml').read_text(encoding='utf-8').replace('vip.mystery0.xhu.timetable.offlineprobe',args.package).replace('targetSdkVersion="28"','targetSdkVersion="37"'),encoding='utf-8')
    run([bt/'aapt.exe','package','-f','-M',output/'AndroidManifest.xml','-I',jar,'-A',assets,'-F',output/'unsigned.apk'])
    with ZipFile(output/'unsigned.apk','a') as z:
        z.write(dex/'classes.dex','classes.dex')
        for lib in (root/'androidApp/build/generated/tmallDebug/jniLibs/arm64-v8a').glob('libsg*.so'):z.write(lib,'lib/arm64-v8a/'+lib.name)
    run([bt/'zipalign.exe','-f','4',output/'unsigned.apk',output/'aligned.apk'])
    run(['keytool','-genkeypair','-keystore',output/'probe.jks','-alias','probe','-keyalg','RSA','-validity','2','-dname','CN=Offline slim test','-storepass:env','PROBE_PASS','-keypass:env','PROBE_PASS','-noprompt'])
    run([bt/'apksigner.bat','sign','--ks',output/'probe.jks','--ks-pass','env:PROBE_PASS','--out',output/'probe.apk',output/'aligned.apk'])
    (output/'probe.jks').unlink()
    print(output/'probe.apk')
if __name__=='__main__':main()
