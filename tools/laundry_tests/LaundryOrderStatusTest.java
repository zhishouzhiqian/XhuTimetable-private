package vip.mystery0.xhu.timetable.laundry;

import org.json.JSONObject;

/** 模拟数据：验证首页运行状态与剩余时间始终以服务端为准。 */
public final class LaundryOrderStatusTest {
    private static int count;
    private static void check(boolean value) {
        if (!value) throw new AssertionError("status check " + count);
        count++;
    }
    private static JSONObject detail(String pay, String fulfil) throws Exception {
        return new JSONObject().put("payStatus", pay).put("fulfilStatus", fulfil).put("workModeName", "标准洗");
    }
    public static void main(String[] args) throws Exception {
        JSONObject urgent = new JSONObject().put("urgentOrderType", "RUNNING_ORDER")
            .put("remainSeconds", 119).put("isvOrderId", "mock-sequence");
        JSONObject row = LaundryOrderStatus.snapshot(urgent, detail("SUCCEED", "FULFILLING"));
        check(row.getBoolean("running"));
        check(row.getLong("seconds") == 119);
        check(row.getString("reference").equals("mock-sequence"));
        check(row.getString("program").equals("标准洗"));
        check(!row.getBoolean("completed"));
        check(!row.getBoolean("waitingForDevice"));
        check(LaundryOrderStatus.snapshot(urgent, detail("SUCCEED", "WAIT_FULFIL")).getBoolean("waitingForDevice"));
        check(!LaundryOrderStatus.snapshot(urgent, detail("INIT", "WAIT_FULFIL")).getBoolean("waitingForDevice"));
        check(!LaundryOrderStatus.snapshot(urgent, detail("INIT", "FULFILLING")).getBoolean("running"));
        check(!LaundryOrderStatus.snapshot(new JSONObject().put("urgentOrderType", "WAITING_ORDER"),
            detail("SUCCEED", "FULFILLING")).getBoolean("running"));
        row = LaundryOrderStatus.snapshot(urgent, detail("SUCCEED", "COMPLETED"));
        check(row.getBoolean("completed") && !row.getBoolean("running"));
        urgent.put("remainSeconds", 0);
        row = LaundryOrderStatus.snapshot(urgent, detail("SUCCEED", "FULFILLING"));
        check(row.getBoolean("running") && !row.getBoolean("completed"));
        check(row.getLong("seconds") == 0);
        urgent.put("remainSeconds", "1.5");
        check(LaundryOrderStatus.snapshot(urgent, detail("SUCCEED", "FULFILLING")).getLong("seconds") == -1);
        urgent.put("remainSeconds", 604801);
        check(LaundryOrderStatus.snapshot(urgent, detail("SUCCEED", "FULFILLING")).getLong("seconds") == -1);
        urgent.remove("remainSeconds");
        check(LaundryOrderStatus.snapshot(urgent, detail("SUCCEED", "FULFILLING")).getLong("seconds") == -1);
        System.out.println(count + " order snapshot checks passed");
    }
}
