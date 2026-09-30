package vip.mystery0.xhu.timetable.laundry;

public final class LaundryOrderPolicyTest {
    private static void equal(Object actual,Object expected) {
        if (!actual.equals(expected)) throw new AssertionError(actual+" != "+expected);
    }
    public static void main(String[] args) {
        equal(LaundryOrderPolicy.label("TO_PAY","FULFILLING"),"付款尚未确认");
        equal(LaundryOrderPolicy.label("SUCCEED","FULFILLING"),"已付款 · 运行中");
        equal(LaundryOrderPolicy.label("SUCCEED","COMPLETED"),"已付款 · 洗衣完成");
        equal(LaundryOrderPolicy.label("CLOSED","ERROR_COMPLETE"),"订单已关闭");
        equal(LaundryOrderPolicy.label("SUCCEED","UNKNOWN"),"已付款 · 等待设备状态确认");
        equal(LaundryOrderPolicy.label("UNKNOWN","COMPLETED"),"付款尚未确认");
        equal(LaundryOrderPolicy.remaining(119,23),96L);
        equal(LaundryOrderPolicy.remaining(119,150),0L);
        equal(LaundryOrderPolicy.remaining(119,-10),119L);
        System.out.println("9 order policy checks passed");
    }
}
