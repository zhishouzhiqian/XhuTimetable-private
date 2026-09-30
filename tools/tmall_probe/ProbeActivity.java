package vip.mystery0.xhu.timetable.offlineprobe;

import android.app.Activity;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Method;
import java.net.URLEncoder;
import java.util.HashMap;
import java.util.Map;
import org.json.JSONObject;

/** 依赖本机官方 APK 的隔离诊断；不能作为独立签名产品实现。 */
public final class ProbeActivity extends Activity {
    private String stage = "start";

    // 类和公开资源来自来源 APK，所有私有目录与设置必须使用探针自己的目录。
    private static final class ProbeContext extends ContextWrapper {
        private final Context owner;
        ProbeContext(Context source, Context owner) { super(source); this.owner = owner; }
        @Override public Context getApplicationContext() { return this; }
        @Override public File getDir(String name, int mode) { return owner.getDir(name, mode); }
        @Override public File getFilesDir() { return owner.getFilesDir(); }
        @Override public File getCacheDir() { return owner.getCacheDir(); }
        @Override public File getCodeCacheDir() { return owner.getCodeCacheDir(); }
        @Override public File getDataDir() { return owner.getDataDir(); }
        @Override public File getNoBackupFilesDir() { return owner.getNoBackupFilesDir(); }
        @Override public File getDatabasePath(String name) { return owner.getDatabasePath(name); }
        @Override public SharedPreferences getSharedPreferences(String name, int mode) {
            return owner.getSharedPreferences(name, mode);
        }
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this);
        text.setText("离线签名诊断，不发送登录或设备请求。");
        setContentView(text);
        new Thread(() -> {
            JSONObject report = new JSONObject();
            try {
                if (checkSelfPermission("android.permission.INTERNET") == PackageManager.PERMISSION_GRANTED) {
                    throw new IllegalStateException();
                }
                report.put("internet_permission", false);
                stage = "load_snapshot";
                JSONObject input;
                try (java.io.InputStream stream = getIntent().getBooleanExtra("useNextSnapshot", false)
                    ? new java.io.FileInputStream(new File(getFilesDir(), "next-snapshot.json"))
                    : getAssets().open("snapshot.json")) {
                    java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
                    byte[] buffer = new byte[4096]; int size;
                    while ((size = stream.read(buffer)) != -1) bytes.write(buffer, 0, size);
                    input = new JSONObject(bytes.toString("UTF-8"));
                }
                HashMap<String, String> frozen = new HashMap<>();
                for (java.util.Iterator<String> it = input.keys(); it.hasNext();) {
                    String key = it.next(); frozen.put(key, input.getString(key));
                }
                stage = "load_source_classes";
                Context source = createPackageContext("com.tmall.campus.and",
                    Context.CONTEXT_INCLUDE_CODE | Context.CONTEXT_IGNORE_SECURITY);
                Context context = new ProbeContext(source, getApplicationContext());
                ClassLoader loader = source.getClassLoader();
                loader.loadClass("mtopsdk.common.util.TBSdkLog")
                    .getMethod("setPrintLog", boolean.class).invoke(null, false);
                stage = "initialize_security";
                Class<?> configClass = loader.loadClass("mtopsdk.mtop.global.MtopConfig");
                Object config = configClass.getConstructor(String.class).newInstance("OFFLINE_PROBE");
                configClass.getField("context").set(config, context);
                configClass.getField("appKey").set(config, frozen.get("appKey"));
                Class<?> signerClass = loader.loadClass("mtopsdk.security.InnerSignImpl");
                Object signer = signerClass.getConstructor().newInstance();
                signerClass.getMethod("init", configClass).invoke(signer, config);
                Method sign = signerClass.getMethod("getUnifiedSign", HashMap.class, HashMap.class,
                    String.class, String.class, boolean.class, String.class);
                // 使用 SDK 默认 authCode；不从 HAR 读取任何授权码或会话。
                String authCode = (String) configClass.getField("authCode").get(config);
                stage = "generate_factors";
                Map<?, ?> first = (Map<?, ?>) sign.invoke(signer, new HashMap<>(frozen),
                    new HashMap<String, String>(), frozen.get("appKey"), authCode, false, "offline-1");
                if (first == null) throw new IllegalStateException();
                String[] keys = {"x-sign", "x-mini-wua", "x-sgext", "x-umt"};
                JSONObject lengths = new JSONObject();
                boolean complete = true;
                for (String key : keys) {
                    Object value = first.get(key);
                    int length = value instanceof String ? ((String) value).length() : 0;
                    lengths.put(key, length); complete &= length > 0;
                }
                report.put("raw_factor_lengths", lengths);
                report.put("all_factors_present", complete);
                if (!complete) throw new IllegalStateException();
                stage = "sdk_header_comparison";
                HashMap<String, String> params = new HashMap<>(frozen);
                params.put("sign", (String) first.get("x-sign"));
                params.put("umt", (String) first.get("x-umt"));
                params.put("x-mini-wua", (String) first.get("x-mini-wua"));
                params.put("x-sgext", (String) first.get("x-sgext"));
                Class<?> converterClass = loader.loadClass("mtopsdk.mtop.protocol.converter.impl.InnerNetworkConverter");
                Object converter = converterClass.getConstructor().newInstance();
                Map<?, ?> sdkHeaders = (Map<?, ?>) converterClass
                    .getMethod("buildRequestHeaders", Map.class, Map.class, boolean.class)
                    .invoke(converter, new HashMap<>(params), new HashMap<String, String>(), true);
                boolean matches = true;
                String[][] mapping = {{"x-t", "t"}, {"x-appkey", "appKey"}, {"x-pv", "pv"},
                    {"x-utdid", "utdid"}, {"x-ttid", "ttid"}, {"x-features", "x-features"},
                    {"x-extdata", "extdata"}, {"x-sign", "sign"}, {"x-mini-wua", "x-mini-wua"},
                    {"x-sgext", "x-sgext"}, {"x-umt", "umt"}, {"x-devid", "deviceId"}};
                int compared = 0;
                for (String[] pair : mapping) {
                    String value = params.get(pair[1]);
                    if (value != null) {
                        compared++;
                        matches &= URLEncoder.encode(value, "UTF-8").equals(sdkHeaders.get(pair[0]));
                    }
                }
                report.put("checked_header_count", compared);
                report.put("sdk_headers_match_contract", matches);
                report.put("request_has_device_id", sdkHeaders.containsKey("x-devid"));
                report.put("request_has_session", sdkHeaders.containsKey("x-sid"));
                HashMap<String, String> secondInput = new HashMap<>(frozen);
                secondInput.put("t", Long.toString(Long.parseLong(frozen.get("t")) + 1));
                stage = "timestamp_variation";
                Map<?, ?> second = (Map<?, ?>) sign.invoke(signer, secondInput,
                    new HashMap<String, String>(), frozen.get("appKey"), authCode, false, "offline-1");
                report.put("second_sign_present", second != null && second.get("x-sign") instanceof String
                    && !((String) second.get("x-sign")).isEmpty());
                report.put("sign_changed_with_new_timestamp", second != null
                    && second.get("x-sign") instanceof String
                    && !first.get("x-sign").equals(second.get("x-sign")));
                report.put("snapshot_body_unchanged", input.getString("data").equals(frozen.get("data")));
                // 仅显式准备网络验收时，把本次新生成字段暂存在探针私有目录。
                // 探针仍无网络权限；本机验证器只读入内存，卸载会删除此文件。
                if (getIntent().getBooleanExtra("prepareCandidate", false)) {
                    if (!matches) throw new IllegalStateException();
                    JSONObject candidate = new JSONObject();
                    candidate.put("parameters", input);
                    JSONObject factors = new JSONObject();
                    for (String key : keys) factors.put(key, first.get(key));
                    candidate.put("raw_factors", factors);
                    JSONObject wire = new JSONObject();
                    wire.put("path", "/gw/" + frozen.get("api").toLowerCase(java.util.Locale.ROOT)
                        + "/" + frozen.get("v") + "/");
                    wire.put("query", "data=" + URLEncoder.encode(frozen.get("data"), "UTF-8"));
                    JSONObject encoded = new JSONObject();
                    for (String[] pair : mapping) {
                        if (params.containsKey(pair[1])) encoded.put(pair[0], sdkHeaders.get(pair[0]));
                    }
                    wire.put("headers", encoded);
                    candidate.put("wire", wire);
                    try (FileOutputStream out = new FileOutputStream(new File(getFilesDir(), "candidate.json"))) {
                        out.write(candidate.toString().getBytes("UTF-8"));
                    }
                    report.put("candidate_prepared", true);
                }
                report.put("finished", true);
            } catch (Throwable error) {
                try { report.put("finished", false); report.put("failed_stage", stage);
                    // 不记录异常消息或堆栈；组件可能在其中带入签名输入。
                    while (error instanceof java.lang.reflect.InvocationTargetException
                        && error.getCause() != null) error = error.getCause();
                    report.put("exception_type", error.getClass().getSimpleName());
                    try { report.put("security_error_code", error.getClass().getMethod("getErrorCode").invoke(error)); }
                    catch (Exception ignored) { }
                } catch (Exception ignored) { }
            }
            try (FileOutputStream out = new FileOutputStream(new File(getFilesDir(), "report.json"))) {
                out.write(report.toString().getBytes("UTF-8"));
                Log.i("TmContractProbe", "离线诊断完成，报告仅含长度和布尔值。");
            } catch (Exception ignored) { }
        }, "tmall-offline-probe").start();
    }
}
