package vip.mystery0.xhu.timetable.laundry;

import android.content.Context;
import android.os.Build;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URL;
import java.net.URLEncoder;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Locale;
import java.util.Map;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONArray;
import org.json.JSONObject;

/** Android 内置组件兼容路线：不需要安装天猫校园，仍依赖其组件。 */
final class CampusClient {
    private final Context owner;
    private final CampusSessionStore store;
    private JSONObject state;
    private JSONObject config;
    private ClassLoader loader;
    private Context securityContext;
    private Object signer;
    private String authCode;
    private JSONObject paymentInput, paymentQuote;
    private String paymentResNo, paymentKey;
    private boolean initialized;
    private final CampusReadCache readCache = new CampusReadCache();
    private java.lang.reflect.Method unifiedSign, buildHeaders;
    private Object converter;
    String stage = "初始化";
    private static final String PROFILE = "mtop.tmall.campus.member.app.user.get";
    private static final String ORDERS = "mtop.tmall.campus.share.applet.general.user.urgent.order.list";
    private static final String ORDER_DETAIL = "mtop.tmall.campus.share.applet.general.order.detail.get";
    private static final String ORDER_HISTORY = "mtop.tmall.campus.share.applet.general.user.order.list";
    private static final String BUILDINGS = "mtop.tmall.campus.share.applet.building.list";
    private static final String DEVICES = "mtop.tmall.campus.share.applet.device.list";
    private static final String DEVICE_INFO = "mtop.tmall.campus.share.applet.general.device.info";
    private static final String RENDER_ORDER = "mtop.tmall.campus.share.order.render.execute";
    private static final String SEQUENCE = "mtop.tmall.campus.share.general.uuid.get";
    private static final String CREATE_ORDER = "mtop.tmall.campus.share.order.create.execute";
    private static final String CHECKOUT = "mtop.tmall.campus.cashier.checkout.query";
    private static final String PAYMETHOD = "mtop.tmall.campus.cashier.paymethod.query";
    private static final String LOGIN = "mtop.taobao.mloginservice.snslogin";
    private static final String REGISTER = "mtop.sys.newdeviceid";

    CampusClient(Context context) { owner = context.getApplicationContext(); store = new CampusSessionStore(owner); }

    void initialize() throws Exception {
        long started = android.os.SystemClock.elapsedRealtime();
        stage = "加载内置校园组件";
        if (config == null) try (InputStream in = owner.getAssets().open("tmall-public.json")) { config = new JSONObject(read(in)); }
        state = store.load();
        sessionChanged();
        if (initialized) {
            metric("initialize_reused", started);
            return;
        }
        if (state.optString("utdid").isEmpty()) {
            byte[] random = new byte[18]; new SecureRandom().nextBytes(random);
            state.put("utdid", Base64.encodeToString(random, Base64.NO_WRAP));
            store.save(state);
        }
        securityContext = BundledCampusRuntime.open(owner);
        loader = securityContext.getClassLoader();
        loader.loadClass("mtopsdk.common.util.TBSdkLog").getMethod("setPrintLog", boolean.class).invoke(null, false);
        Class<?> configClass = loader.loadClass("mtopsdk.mtop.global.MtopConfig");
        Object sdkConfig = configClass.getConstructor(String.class).newInstance("CAMPUS_LOGIN_TEST");
        configClass.getField("context").set(sdkConfig, securityContext);
        configClass.getField("appKey").set(sdkConfig, config.getString("appKey"));
        Class<?> signerClass = loader.loadClass("mtopsdk.security.InnerSignImpl");
        signer = signerClass.getConstructor().newInstance();
        signerClass.getMethod("init", configClass).invoke(signer, sdkConfig);
        authCode = (String) configClass.getField("authCode").get(sdkConfig);
        if (state.optString("deviceId").isEmpty()) {
            stage = "注册当前设备";
            JSONObject data = new JSONObject().put("new_device", "true").put("device_global_id", state.getString("utdid"))
                .put("c0", Build.BRAND).put("c1", Build.MODEL);
            for (int i = 2; i < 7; i++) data.put("c" + i, "");
            String device = request(REGISTER, "4.0", data, false).getJSONObject("data").getString("device_id");
            if (!device.matches("[A-Za-z0-9_=\\-]{44}")) throw new IllegalStateException();
            state.put("deviceId", device); store.save(state);
        }
        stage = "检查登录安全字段";
        riskData();
        unifiedSign = signer.getClass().getMethod("getUnifiedSign", HashMap.class, HashMap.class,
            String.class, String.class, boolean.class, String.class);
        Class<?> converterClass = loader.loadClass("mtopsdk.mtop.protocol.converter.impl.InnerNetworkConverter");
        converter = converterClass.getConstructor().newInstance();
        buildHeaders = converterClass.getMethod("buildRequestHeaders", Map.class, Map.class, boolean.class);
        initialized = true;
        BundledCampusRuntime.pruneOldArchives(owner);
        android.util.Log.i("CampusLoginTest", "device_ready=true;login_security_ready=true");
        stage = "准备短信登录";
        metric("initialize_cold", started);
    }

    boolean hasSession() { return state != null && !state.optString("sid").isEmpty(); }
    String loginUrl() throws Exception {
        return "https://havanalogin.taobao.com/taobao_oauth_common.htm?appName=taobao-oauth-common&appEntrance=sdk-common"
            + "&needTopToken=true&topTokenAppName=" + encode(config.getString("appKey"));
    }
    void forgetSession() throws Exception { state.remove("sid"); state.remove("uid"); sessionChanged(); store.save(state); }

    private void sessionChanged() {
        if (readCache.session(state.optString("uid"), state.optString("sid"))) {
            paymentInput = null; paymentQuote = null; paymentResNo = null; paymentKey = null;
        }
    }

    private static void metric(String stage, long start) {
        android.util.Log.d("CampusPerf", "stage=" + stage + ";elapsed_ms=" + (android.os.SystemClock.elapsedRealtime() - start));
    }

    private JSONObject riskData() throws Exception {
        // 与登录 SDK 一致：WUA 使用毫秒时间戳和当前安全环境，不能复用 HAR 内容。
        String time = Long.toString(System.currentTimeMillis());
        Class<?> managerClass = loader.loadClass("com.alibaba.wireless.security.open.SecurityGuardManager");
        Object manager = managerClass.getMethod("getInstance", Context.class).invoke(null, securityContext);
        Class<?> bodyClass = loader.loadClass("com.alibaba.wireless.security.open.securitybody.ISecurityBodyComponent");
        Object body = managerClass.getMethod("getInterface", Class.class).invoke(manager, bodyClass);
        String wua = (String) bodyClass.getMethod("getSecurityBodyDataEx", String.class, String.class,
            String.class, HashMap.class, int.class, int.class).invoke(body, time, config.getString("appKey"), "", null, 4, 0);
        Class<?> umidClass = loader.loadClass("com.alibaba.wireless.security.open.umid.IUMIDComponent");
        Object umid = managerClass.getMethod("getInterface", Class.class).invoke(manager, umidClass);
        String umidToken = (String) umidClass.getMethod("getSecurityToken", int.class).invoke(umid, 0);
        if (wua == null || wua.isEmpty() || umidToken == null || umidToken.isEmpty()) throw new IllegalStateException();
        return new JSONObject().put("appStore", config.getString("ttid"))
            .put("deviceBrand", Build.MANUFACTURER).put("deviceModel", Build.MODEL).put("deviceName", Build.MODEL)
            .put("osName", "android").put("osVersion", Build.VERSION.RELEASE).put("screenSize", "0x0")
            .put("t", time).put("umidToken", umidToken).put("wua", wua);
    }

    void exchange(String token) throws Exception {
        stage = "生成本次登录安全字段";
        JSONObject risk = riskData();
        JSONObject info = new JSONObject().put("appName", config.getString("appKey"))
            .put("appVersion", "android_5.7.0").put("deviceId", state.getString("deviceId"))
            .put("deviceName", Build.MANUFACTURER + " " + Build.MODEL).put("locale", "zh_CN")
            .put("sdkVersion", "android_5.6.8.5").put("site", 96).put("snsType", "taobao")
            .put("t", 0).put("token", token).put("ttid", config.getString("ttid"))
            .put("useAcitonType", true).put("useDeviceToken", true).put("utdid", state.getString("utdid"))
            .put("ext", new JSONObject().put("pad", false).put("firstLogin", true).put("huaweiLogin", false));
        stage = "交换校园会话";
        JSONObject result = request(LOGIN, "1.0", new JSONObject().put("snsLoginInfo", info.toString())
            .put("riskControlInfo", risk.toString()).put("ext", "{}"), false).getJSONObject("data");
        JSONObject value = result.optJSONObject("returnValue");
        if (value == null || value.optString("sid").isEmpty()) throw new IllegalStateException();
        state.put("sid", value.getString("sid"));
        state.put("uid", value.optString("hid"));
        sessionChanged();
        // 先只留内存；本人资料和订单验证通过后才保存会话。
    }

    int verify() throws Exception {
        long started = android.os.SystemClock.elapsedRealtime();
        readCache.discardUrgent();
        stage = "验证本人资料";
        JSONObject profile = request(PROFILE, "1.0", new JSONObject().put("platForm", "android"), true).getJSONObject("data");
        if (profile.optString("openUserId").isEmpty() && profile.optString("phone").isEmpty()) throw new IllegalStateException();
        stage = "验证洗衣订单";
        long observedAt = android.os.SystemClock.elapsedRealtime();
        JSONObject data = request(ORDERS, "1.0", new JSONObject().put("requestType", "USER_URGENT_ORDER_LIST")
            .put("requestJson", new JSONObject().put("isv", "CAMPUS").put("businessType", "WASH_AND_CARE").toString()), true)
            .getJSONObject("data");
        if (data.optBoolean("fail", true)) throw new IllegalStateException();
        JSONArray orders = data.getJSONObject("data").getJSONArray("urgentOrderListResponse");
        if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
        store.save(state);
        readCache.verified(orders, observedAt, android.os.SystemClock.elapsedRealtime());
        metric("verify", started);
        return orders.length();
    }

    void allowLoginHandoff() { readCache.allowLoginHandoff(); }
    void verifyForEntry() throws Exception {
        if (!readCache.takeLoginHandoff(android.os.SystemClock.elapsedRealtime())) verify();
        else android.util.Log.d("CampusPerf", "stage=verify_handoff;requests_saved=2");
    }

    // 只读查询；订单标识仅用于本人会话内的详情核验，不记录日志或落盘。
    JSONArray runningOrders() throws Exception {
        return runningOrderSnapshot(false).orders;
    }

    CampusOrderSnapshot runningOrderSnapshot(boolean useVerified) throws Exception {
        JSONObject scope = new JSONObject().put("isv", "CAMPUS").put("businessType", "WASH_AND_CARE");
        CampusOrderSnapshot saved = useVerified ? readCache.takeUrgent(android.os.SystemClock.elapsedRealtime()) : null;
        if (!useVerified) readCache.discardUrgent();
        long observedAt = saved == null ? android.os.SystemClock.elapsedRealtime() : saved.observedAt;
        JSONArray urgent = saved == null ? businessData(request(ORDERS, "1.0", envelope("USER_URGENT_ORDER_LIST", scope), true))
            .getJSONArray("urgentOrderListResponse") : saved.orders;
        if (saved != null) android.util.Log.d("CampusPerf", "stage=urgent_reused;requests_saved=1");
        if (urgent.length() > 20) throw new IllegalStateException("RESPONSE_INVALID");
        JSONArray result = new JSONArray();
        for (int i = 0; i < urgent.length(); i++) {
            JSONObject row = urgent.getJSONObject(i);
            JSONObject detail = orderDetail(row);
            result.put(LaundryOrderStatus.snapshot(row, detail));
        }
        return new CampusOrderSnapshot(result, observedAt);
    }

    JSONArray recentOrders() throws Exception {
        JSONObject scope = new JSONObject().put("isv", "CAMPUS").put("businessType", "WASH_AND_CARE")
            .put("pageNum", 1).put("pageSize", 10).put("isQueryToPayOrderList", false);
        JSONArray rows = businessData(request(ORDER_HISTORY, "1.0", envelope("USER_ORDER_LIST", scope), true))
            .getJSONArray("orderListResponses");
        JSONArray result = new JSONArray();
        for (int i = 0; i < Math.min(rows.length(), 10); i++) {
            JSONObject row = rows.getJSONObject(i);
            result.put(new JSONObject().put("name", row.optString("deviceName", "洗衣机"))
                .put("status", LaundryOrderPolicy.label(row.optString("payStatusEnum"), row.optString("fulfilStatus")))
                .put("reference", row.optString("isvOrderId"))
                .put("completed", "COMPLETED".equals(row.optString("fulfilStatus")))
                .put("program", row.optString("workModeName")));
        }
        return result;
    }

    private JSONObject orderDetail(JSONObject row) throws Exception {
        JSONObject scope = new JSONObject().put("isv", "CAMPUS").put("businessType", "WASH_AND_CARE");
        for (String key : new String[]{"bizOrderId", "mixBuyerId", "isvOrderId"}) scope.put(key, row.getString(key));
        JSONObject detail = businessData(request(ORDER_DETAIL, "1.0", envelope("ORDER_DETAIL_GET", scope), true))
            .getJSONObject("response");
        String id = detail.optString("bizOrderIdStr", detail.optString("bizOrderId"));
        if (!row.getString("bizOrderId").equals(id)) throw new IllegalStateException("ORDER_MISMATCH");
        return detail;
    }

    private static JSONObject businessData(JSONObject response) throws Exception {
        JSONObject data = response.getJSONObject("data");
        if (data.optBoolean("fail", true)) throw new IllegalStateException("SERVER_REJECTED");
        return data.getJSONObject("data");
    }

    JSONObject lookupDevice(String resNo) throws Exception {
        if (!hasSession() || resNo == null || !resNo.matches("[A-Za-z0-9_-]{1,128}"))
            throw new IllegalStateException("SESSION_EXPIRED");
        stage = "查询洗衣机详情";
        String known = readCache.device(resNo);
        if (known != null) {
            try { return deviceSnapshot(resNo, known); }
            catch (IllegalStateException error) {
                String code = error.getMessage();
                if (!"SERVER_REJECTED".equals(code) && !"DEVICE_REJECTED".equals(code) && !"DEVICE_MISMATCH".equals(code)) throw error;
                readCache.forgetDevice(resNo);
            }
        }
        try {
            return deviceSnapshot(resNo, null);
        } catch (IllegalStateException error) {
            // 官方页面允许省略 deviceId；仅在服务端拒绝时按已抓到的列表流程补查。
            if (!"SERVER_REJECTED".equals(error.getMessage()) && !"DEVICE_REJECTED".equals(error.getMessage()))
                throw error;
        }
        stage = "查找洗衣机";
        JSONObject matched = findDevice(resNo, null, 1, true);
        if (matched == null) {
            JSONArray buildings = request(BUILDINGS, "1.0", envelope("USER_BUILDING_LIST",
                new JSONObject().put("relationStatus", "ON").put("businessType", "WASH_AND_CARE")), true)
                .getJSONObject("data").getJSONArray("data");
            int remainingRequests = 32;
            for (int i = 0; i < buildings.length() && matched == null && remainingRequests > 0; i++) {
                long buildingId = buildings.getJSONObject(i).getLong("buildingId");
                for (int page = 1; page <= 3 && matched == null && remainingRequests > 0; page++) {
                    remainingRequests--;
                    matched = findDevice(resNo, buildingId, page, false);
                    if (!lastDevicePageHasMore) break;
                }
            }
        }
        if (matched == null) throw new IllegalStateException("DEVICE_NOT_FOUND");
        String deviceId = matched.getString("deviceId");
        stage = "查询洗衣机详情";
        return deviceSnapshot(resNo, deviceId);
    }

    JSONObject previewOrder(String resNo, String programKey) throws Exception {
        // 点击预览后重新读取设备及价格，避免使用过期或由界面修改的价格。
        JSONObject device = lookupDevice(resNo);
        JSONObject input = LaundryOrderProtocol.renderInput(device, programKey);
        stage = "查询实际应付金额";
        JSONObject response = request(RENDER_ORDER, "1.0", envelope("RENDER_ORDER", input), true)
            .getJSONObject("data").getJSONObject("response");
        JSONObject quote = LaundryOrderProtocol.quote(input, response);
        quote.put("device",device.optString("name"));
        quote.put("location",device.optString("building")+" "+device.optString("floor"));
        paymentInput = input; paymentQuote = response; paymentResNo = resNo; paymentKey = programKey;
        return quote;
    }

    private CampusSessionStore paymentStore() { return new CampusSessionStore(owner, "campus-payment.enc"); }

    JSONObject pendingPayment() throws Exception {
        JSONObject pending = paymentStore().load();
        if (pending.length() > 0 && !state.optString("uid").equals(pending.optString("owner")))
            throw new IllegalStateException("PAYMENT_ACCOUNT_MISMATCH");
        return pending;
    }

    // 持久化意图后至多发出一次创建请求；结果不明确时保留意图，不自动重试。
    JSONObject createConfirmedPayment(String confirmedPay) throws Exception {
        synchronized (CampusClient.class) {
            if (pendingPayment().length() > 0) throw new IllegalStateException("PAYMENT_PENDING");
            if (paymentInput == null) throw new IllegalStateException("QUOTE_REQUIRED");
            JSONObject latest = previewOrder(paymentResNo, paymentKey);
            if (!confirmedPay.equals(latest.getString("pay"))) throw new IllegalStateException("PRICE_CHANGED");
            JSONObject scope = new JSONObject().put("isv", "CAMPUS").put("businessType", "WASH_AND_CARE")
                .put("sequenceType", "ORDER_CREATE_OUT_ID_SEQUENCE");
            Object sequence = businessData(request(SEQUENCE, "1.0", envelope("OUT_UUID_SEQUENCE_GET", scope), true)).get("response");
            JSONObject input = LaundryPaymentProtocol.createInput(paymentInput, paymentQuote, sequence);
            JSONObject pending = new JSONObject().put("owner", state.getString("uid"))
                .put("isvOrderId", sequence.toString()).put("amount", input.getLong("paymentAmount"))
                .put("resNo", paymentResNo).put("program", latest.getString("program"))
                .put("device",latest.optString("device")).put("location",latest.optString("location"));
            paymentStore().save(pending);
            JSONObject created = request(CREATE_ORDER, "1.0", envelope("CREATE_ORDER", input), true)
                .getJSONObject("data").getJSONObject("orderParamDto");
            LaundryPaymentProtocol.checkCreated(input, created);
            pending.put("checkoutId", created.get("checkoutId").toString());
            paymentStore().save(pending);
            return pending;
        }
    }

    JSONObject recoverPayment() throws Exception {
        JSONObject pending = pendingPayment();
        if (pending.length() == 0 || pending.has("checkoutId")) return pending;
        JSONObject scope = new JSONObject().put("isv", "CAMPUS").put("businessType", "WASH_AND_CARE")
            .put("pageNum", 1).put("pageSize", 10).put("isQueryToPayOrderList", false);
        JSONArray rows = businessData(request(ORDER_HISTORY, "1.0", envelope("USER_ORDER_LIST", scope), true))
            .getJSONArray("orderListResponses");
        for (int i=0;i<rows.length();i++) {
            JSONObject row = rows.getJSONObject(i);
            if (!pending.getString("isvOrderId").equals(row.optString("isvOrderId"))) continue;
            JSONObject normalized = new JSONObject(row.toString());
            normalized.put("bizOrderId", row.optString("bizOrderIdStr",row.optString("bizOrderId")));
            JSONObject detail = orderDetail(normalized);
            if (LaundryAmounts.cents(detail.get("paymentAmount")) != pending.getLong("amount"))
                throw new IllegalStateException("PAYMENT_MISMATCH");
            pending.put("checkoutId", detail.get("checkoutId").toString());
            paymentStore().save(pending); return pending;
        }
        throw new IllegalStateException("CREATE_UNCERTAIN");
    }

    JSONObject paymentCheckout() throws Exception {
        JSONObject pending = recoverPayment();
        if (!pending.has("checkoutId")) throw new IllegalStateException("CREATE_UNCERTAIN");
        JSONObject data = request(CHECKOUT, "1.0", new JSONObject().put("checkoutId",pending.getString("checkoutId")), true)
            .getJSONObject("data");
        LaundryPaymentProtocol.checkCheckout(pending, data);
        return data;
    }

    String wechatPaymentUri() throws Exception {
        JSONObject checkout = paymentCheckout();
        if (!"INIT".equals(checkout.getString("status"))) throw new IllegalStateException("PAYMENT_NOT_INIT");
        JSONObject pending = pendingPayment();
        String checkoutId = pending.getString("checkoutId");
        JSONObject data = request(PAYMETHOD, "1.0", new JSONObject().put("checkoutId",checkoutId)
            .put("extraAttr",new JSONObject().put("bizOrderId",checkoutId).toString()),true).getJSONObject("data");
        return LaundryPaymentProtocol.wechatUri(checkoutId, checkout, data.getJSONArray("cashierPayMethodList"));
    }

    void acknowledgeTerminalPayment() throws Exception {
        synchronized (CampusClient.class) {
            String status = paymentCheckout().getString("status");
            if (!"SUCCESS".equals(status) && !"CLOSE".equals(status)) throw new IllegalStateException("PAYMENT_PENDING");
            paymentStore().save(new JSONObject());
        }
    }

    private JSONObject deviceSnapshot(String resNo, String deviceId) throws Exception {
        JSONObject query = new JSONObject()
            .put("isv", "CAMPUS").put("businessType", "WASH_AND_CARE").put("resNo", resNo)
            .put("needAutoSendCoupon", false).put("paymentChannel", "TMXY_APP");
        if (deviceId != null) query.put("deviceId", deviceId);
        JSONObject detail = request(DEVICE_INFO, "1.0", envelope("DEVICE_INFO_GET", query), true)
            .getJSONObject("data");
        if (detail.optBoolean("fail", true)) throw new IllegalStateException("DEVICE_REJECTED");
        JSONObject device = detail.getJSONObject("data").getJSONObject("deviceResponse");
        if (!resNo.equals(device.getString("deviceCode"))
            || (deviceId != null && !deviceId.equals(device.getString("deviceId"))))
            throw new IllegalStateException("DEVICE_MISMATCH");
        JSONObject snapshot = new JSONObject()
            .put("resNo", resNo).put("deviceId", device.getString("deviceId"))
            .put("campusAreaCode", device.opt("campusAreaId"))
            .put("deviceType", device.optString("deviceType"))
            .put("modelType", device.optString("modelType"))
            .put("name", shortText(device.optString("deviceName")))
            .put("building", shortText(device.optString("buildingName")))
            .put("floor", shortText(device.optString("floorName")))
            .put("status", shortText(device.optString("workbenchStatusDESC")))
            .put("canUse", device.optBoolean("deviceCanUse", false));
        JSONArray modes = new JSONArray();
        JSONArray attributes = device.optJSONArray("deviceWorkingModelDTOS");
        if (attributes != null) for (int i = 0; i < attributes.length(); i++) {
            JSONObject attribute = attributes.optJSONObject(i);
            if (attribute == null || !attribute.optBoolean("isSupport", false)) continue;
            JSONArray prices = attribute.optJSONArray("priceModelList");
            if (prices == null) continue;
            for (int j = 0; j < prices.length(); j++) {
                JSONObject price = prices.optJSONObject(j);
                if (price == null || !price.optBoolean("isOpen", false)) continue;
                modes.put(new JSONObject()
                    .put("key", price.optString("key"))
                    .put("attrName", attribute.optString("attrName"))
                    .put("price", price.opt("price"))
                    .put("name", shortText(price.optString("desc")))
                    .put("details", shortText(price.optString("defaultDetails")))
                    .put("priceYuan", shortText(price.optString("priceYuan"))));
            }
        }
        snapshot.put("programs", modes);
        readCache.rememberDevice(resNo, device.getString("deviceId"));
        return snapshot;
    }

    private boolean lastDevicePageHasMore;
    private JSONObject findDevice(String resNo, Long buildingId, int page, boolean choose) throws Exception {
        JSONObject query = new JSONObject().put("pageNum", page).put("pageSize", 20)
            .put("deviceType", "COMMONLY_USED_DEVICE");
        if (choose) query.put("choose", true);
        if (buildingId != null) query.put("buildingIds", new JSONArray().put(buildingId));
        JSONObject result = request(DEVICES, "1.0", envelope("USER_DEVICE_LIST", query), true)
            .getJSONObject("data").getJSONObject("pageResult");
        if (!result.optBoolean("success", false)) throw new IllegalStateException("DEVICE_LIST_REJECTED");
        lastDevicePageHasMore = result.optBoolean("hasMore", false);
        JSONArray rows = result.getJSONArray("data");
        for (int i = 0; i < rows.length(); i++) {
            JSONObject row = rows.getJSONObject(i);
            if (resNo.equals(row.optString("deviceCode"))) return row;
        }
        return null;
    }

    private static JSONObject envelope(String type, JSONObject requestJson) throws Exception {
        return new JSONObject().put("requestType", type).put("requestJson", requestJson.toString());
    }

    private static String shortText(String value) { return value.length() > 128 ? value.substring(0, 128) : value; }

    @SuppressWarnings("unchecked")
    private JSONObject request(String api, String version, JSONObject data, boolean authenticated) throws Exception {
        long started = android.os.SystemClock.elapsedRealtime();
        if (!api.equals(REGISTER) && !api.equals(LOGIN) && !api.equals(PROFILE) && !api.equals(ORDERS)
            && !api.equals(SEQUENCE) && !api.equals(CREATE_ORDER) && !api.equals(CHECKOUT) && !api.equals(PAYMETHOD)
            && !api.equals(ORDER_DETAIL) && !api.equals(ORDER_HISTORY) && !api.equals(BUILDINGS) && !api.equals(DEVICES) && !api.equals(DEVICE_INFO) && !api.equals(RENDER_ORDER))
            throw new IllegalArgumentException();
        HashMap<String, String> params = new HashMap<>();
        for (Iterator<String> it = config.keys(); it.hasNext();) { String key = it.next(); params.put(key, config.getString(key)); }
        String json = data.toString();
        params.put("api", api.toLowerCase(Locale.ROOT)); params.put("v", version);
        params.put("data", json); params.put("t", Long.toString(System.currentTimeMillis() / 1000));
        params.put("utdid", state.getString("utdid"));
        if (api.equals(REGISTER)) params.put("bizId", "4099");
        else params.put("deviceId", state.getString("deviceId"));
        if (authenticated) {
            if (!hasSession()) throw new IllegalStateException();
            params.put("sid", state.getString("sid")); params.put("uid", state.optString("uid"));
        }
        // 设备首次注册发生在初始化完成前，也始终生成本次请求的签名。
        java.lang.reflect.Method signMethod = unifiedSign != null ? unifiedSign : signer.getClass().getMethod("getUnifiedSign",
            HashMap.class, HashMap.class, String.class, String.class, boolean.class, String.class);
        Map<String, String> factors = (Map<String, String>) signMethod
            .invoke(signer, new HashMap<>(params), new HashMap<String, String>(), config.getString("appKey"), authCode, false, "campus-login");
        if (factors == null) throw new IllegalStateException();
        for (String key : new String[]{"x-sign", "x-mini-wua", "x-sgext", "x-umt"})
            if (factors.get(key) == null || factors.get(key).isEmpty()) throw new IllegalStateException();
        params.put("sign", factors.get("x-sign")); params.put("umt", factors.get("x-umt"));
        params.put("x-mini-wua", factors.get("x-mini-wua")); params.put("x-sgext", factors.get("x-sgext"));
        if (buildHeaders == null) {
            Class<?> converterClass = loader.loadClass("mtopsdk.mtop.protocol.converter.impl.InnerNetworkConverter");
            converter = converterClass.getConstructor().newInstance();
            buildHeaders = converterClass.getMethod("buildRequestHeaders", Map.class, Map.class, boolean.class);
        }
        Map<String, String> headers = (Map<String, String>) buildHeaders.invoke(converter, params, new HashMap<String, String>(), true);
        boolean registration = api.equals(REGISTER);
        String form = "data=" + encode(json);
        HttpsURLConnection conn = (HttpsURLConnection) new URL("https://acs.m.taobao.com/gw/" + api + "/" + version + "/"
            + (registration ? "?" + form : "")).openConnection();
        conn.setInstanceFollowRedirects(false); conn.setConnectTimeout(15000); conn.setReadTimeout(15000);
        conn.setRequestMethod(registration ? "GET" : "POST");
        for (Map.Entry<String, String> entry : headers.entrySet()) conn.setRequestProperty(entry.getKey(), entry.getValue());
        try {
            if (!registration) {
                conn.setDoOutput(true); conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded;charset=UTF-8");
                byte[] bytes = form.getBytes("UTF-8"); conn.setFixedLengthStreamingMode(bytes.length);
                try (java.io.OutputStream out = conn.getOutputStream()) { out.write(bytes); }
            }
            if (conn.getResponseCode() != 200) throw new IllegalStateException("HTTP_" + conn.getResponseCode());
            JSONObject response;
            try (InputStream in = conn.getInputStream()) { response = new JSONObject(read(in)); }
            JSONArray ret = response.optJSONArray("ret");
            boolean success = false;
            if (ret != null) for (int i = 0; i < ret.length(); i++) {
                String code = ret.optString(i).split("::", 2)[0];
                if ("SUCCESS".equals(code)) success = true;
                if (code.contains("SESSION_EXPIRED")) { forgetSession(); throw new IllegalStateException("SESSION_EXPIRED"); }
                if (code.equals("FAIL_SYS_ILEGEL_SIGN")) throw new IllegalStateException("SIGN_REJECTED");
            }
            if (!success) throw new IllegalStateException("SERVER_REJECTED");
            return response;
        } finally { conn.disconnect(); metric("request_" + api, started); }
    }
    private static String encode(String value) throws Exception { return URLEncoder.encode(value, "UTF-8"); }
    private static String read(InputStream in) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] buffer = new byte[8192]; int n;
        while ((n = in.read(buffer)) != -1) { out.write(buffer, 0, n); if (out.size() > 2097152) throw new IllegalStateException(); }
        return out.toString("UTF-8");
    }
}
