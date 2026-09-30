package vip.mystery0.xhu.timetable.laundry;

/** 不依赖平台的订单状态规则。 */
final class LaundryOrderPolicy {
    static String label(String pay, String fulfil) {
        if ("CLOSED".equals(pay)) return "订单已关闭";
        if (!"SUCCEED".equals(pay)) return "付款尚未确认";
        if ("COMPLETED".equals(fulfil)) return "已付款 · 洗衣完成";
        if ("FULFILLING".equals(fulfil)) return "已付款 · 运行中";
        if ("ERROR_COMPLETE".equals(fulfil)) return "已付款 · 服务异常，请核对订单";
        return "已付款 · 等待设备状态确认";
    }
    static long remaining(long seconds, long elapsedSeconds) {
        return Math.max(0, seconds - Math.max(0, elapsedSeconds));
    }
}
