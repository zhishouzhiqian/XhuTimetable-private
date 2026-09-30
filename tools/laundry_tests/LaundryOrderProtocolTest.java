package vip.mystery0.xhu.timetable.laundry;

import org.json.JSONArray;
import org.json.JSONObject;

/** 使用虚构设备与金额样本执行，不加载校园客户端，也不联网。 */
public final class LaundryOrderProtocolTest {
    private static int passed;
    private interface Action { void run() throws Exception; }
    private static void rejects(Action action) throws Exception {
        try { action.run(); } catch (Exception expected) { passed++; return; }
        throw new AssertionError("应拒绝无效报价");
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); passed++; }
    private static JSONObject device() throws Exception {
        return new JSONObject().put("canUse", true).put("deviceType", "WASHING_MACHINE")
            .put("modelType", "FIXED_TIME_CHARGE").put("resNo", "test-device").put("deviceId", "test-id")
            .put("campusAreaCode", 1).put("programs", new JSONArray().put(new JSONObject()
                .put("key", "test-mode").put("name", "标准洗").put("attrName", "工作模式").put("price", 400)));
    }
    private static JSONObject response(JSONObject input) throws Exception {
        return new JSONObject().put("resNo", input.getString("resNo")).put("businessType", "WASH_AND_CARE")
            .put("serviceItemDTOList", input.getJSONArray("serviceItemDTOList"))
            .put("totalAmount", 400).put("discountAmount", 50).put("actualPayAmount", 350);
    }
    public static void main(String[] args) throws Exception {
        JSONObject input = LaundryOrderProtocol.renderInput(device(), "test-mode");
        JSONObject quote = LaundryOrderProtocol.quote(input, response(input));
        check("3.50".equals(quote.getString("pay")));
        check("0.50".equals(quote.getString("discount")));
        check(input.getJSONArray("serviceItemDTOList").getJSONObject(0).getLong("unitPrice") == 400);
        check(input.getJSONArray("serviceItemDTOList").getJSONObject(0).get("buyAmount") instanceof String);
        rejects(() -> LaundryOrderProtocol.renderInput(device().put("canUse", false), "test-mode"));
        rejects(() -> LaundryOrderProtocol.renderInput(device(), "closed-mode"));
        rejects(() -> LaundryOrderProtocol.renderInput(device().put("deviceType", "UNKNOWN"), "test-mode"));
        rejects(() -> LaundryOrderProtocol.quote(input, response(input).put("resNo", "different-device")));
        rejects(() -> LaundryOrderProtocol.quote(input, response(input).put("actualPayAmount", 400)));
        rejects(() -> LaundryOrderProtocol.quote(input, response(input).put("discountAmount", -1)));
        rejects(() -> LaundryOrderProtocol.quote(input, response(input).put("actualPayAmount", 350.5)));
        rejects(() -> LaundryOrderProtocol.quote(input, response(input).put("serviceItemDTOList", new JSONArray())));
        System.out.println("LaundryOrderProtocol: " + passed + " passed; network unused");
    }
}
