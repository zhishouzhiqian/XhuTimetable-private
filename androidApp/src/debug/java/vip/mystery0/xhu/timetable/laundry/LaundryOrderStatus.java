package vip.mystery0.xhu.timetable.laundry;

import org.json.JSONObject;

/** 支付和履约分别核验；本地倒计时归零不等于设备完成。 */
final class LaundryOrderStatus {
    static JSONObject snapshot(JSONObject urgent, JSONObject detail) throws Exception {
        String pay = detail.getString("payStatus"), fulfil = detail.getString("fulfilStatus");
        boolean running = "SUCCEED".equals(pay) && "FULFILLING".equals(fulfil)
            && "RUNNING_ORDER".equals(urgent.optString("urgentOrderType"));
        long seconds = -1;
        if (running && urgent.has("remainSeconds")) {
            try { seconds = new java.math.BigDecimal(urgent.get("remainSeconds").toString()).longValueExact(); }
            catch (ArithmeticException | NumberFormatException ignored) { seconds = -1; }
            if (seconds < 0 || seconds > 604800) seconds = -1;
        }
        return new JSONObject().put("name", urgent.optString("deviceName", "洗衣机"))
            .put("program", detail.optString("workModeName", urgent.optString("workModeName")))
            .put("location", detail.optString("buildingName") + " " + detail.optString("floorName"))
            .put("reference", urgent.optString("isvOrderId"))
            .put("completed", "SUCCEED".equals(pay) && "COMPLETED".equals(fulfil))
            .put("waitingForDevice", "SUCCEED".equals(pay) && "WAIT_FULFIL".equals(fulfil))
            .put("running", running).put("status", LaundryOrderPolicy.label(pay, fulfil)).put("seconds", seconds);
    }
}
