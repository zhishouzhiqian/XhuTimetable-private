package vip.mystery0.xhu.timetable.laundry;

import org.json.JSONArray;
import org.json.JSONObject;

/** 已抓到的只读订单预览契约；所有金额按分处理，不信任页面传回的价格。 */
final class LaundryOrderProtocol {
    static JSONObject renderInput(JSONObject device, String key) throws Exception {
        if (!device.getBoolean("canUse")) throw new IllegalStateException("DEVICE_UNAVAILABLE");
        if (!"WASHING_MACHINE".equals(device.getString("deviceType")) ||
            !"FIXED_TIME_CHARGE".equals(device.getString("modelType"))) throw new IllegalStateException("UNSUPPORTED_DEVICE");
        JSONObject selected = null;
        JSONArray programs = device.getJSONArray("programs");
        for (int i = 0; i < programs.length(); i++) {
            JSONObject p = programs.getJSONObject(i);
            if (key.equals(p.optString("key"))) {
                if (selected != null) throw new IllegalStateException("AMBIGUOUS_PROGRAM");
                selected = p;
            }
        }
        if (selected == null) throw new IllegalStateException("PROGRAM_UNAVAILABLE");
        long price = cents(selected, "price");
        JSONObject item = new JSONObject().put("serviceItemId", key).put("serviceItemName", selected.getString("name"))
            .put("buyAmount", "1").put("unitPrice", price).put("linePriceFee", price)
            .put("attrName", selected.getString("attrName"));
        return new JSONObject().put("isv", "CAMPUS").put("businessType", "WASH_AND_CARE")
            .put("orderTypeCode", "SERVICE_ORDER").put("resNo", device.getString("resNo"))
            .put("deviceId", device.getString("deviceId")).put("campusAreaCode", device.getLong("campusAreaCode"))
            .put("paymentChannel", "TMXY_APP").put("deviceType", device.getString("deviceType"))
            .put("modelType", device.getString("modelType"))
            .put("serviceItemDTOList", new JSONArray().put(item)).put("promotionDetailDTOList", new JSONArray());
    }

    static JSONObject quote(JSONObject input, JSONObject response) throws Exception {
        if (!input.getString("resNo").equals(response.getString("resNo")) ||
            !"WASH_AND_CARE".equals(response.getString("businessType"))) throw new IllegalStateException("QUOTE_MISMATCH");
        JSONArray rows = response.getJSONArray("serviceItemDTOList");
        JSONObject selected = input.getJSONArray("serviceItemDTOList").getJSONObject(0);
        if (rows.length() != 1 || !selected.getString("serviceItemId").equals(rows.getJSONObject(0).getString("serviceItemId")))
            throw new IllegalStateException("QUOTE_MISMATCH");
        long total = cents(response, "totalAmount"), discount = cents(response, "discountAmount"), pay = cents(response, "actualPayAmount");
        LaundryAmounts.validate(total, discount, pay);
        return new JSONObject().put("program", selected.getString("serviceItemName"))
            .put("total", LaundryAmounts.yuan(total)).put("discount", LaundryAmounts.yuan(discount)).put("pay", LaundryAmounts.yuan(pay));
    }

    private static long cents(JSONObject value, String key) throws Exception {
        return LaundryAmounts.cents(value.get(key));
    }
}
