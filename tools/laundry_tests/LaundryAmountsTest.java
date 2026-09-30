package vip.mystery0.xhu.timetable.laundry;

public final class LaundryAmountsTest {
    private static int passed;
    private static void check(boolean ok) { if (!ok) throw new AssertionError(); passed++; }
    private static void rejects(Runnable action) {
        try { action.run(); } catch (RuntimeException expected) { passed++; return; }
        throw new AssertionError();
    }
    public static void main(String[] args) {
        check("0.50".equals(LaundryAmounts.yuan(LaundryAmounts.cents(50))));
        check("4.00".equals(LaundryAmounts.yuan(LaundryAmounts.cents("400"))));
        check("0.01".equals(LaundryAmounts.yuan(1)));
        check("0.00".equals(LaundryAmounts.yuan(0)));
        LaundryAmounts.validate(400, 50, 350); passed++;
        LaundryAmounts.validate(50, 50, 0); passed++;
        rejects(() -> LaundryAmounts.cents("0.5"));
        rejects(() -> LaundryAmounts.cents(-1));
        rejects(() -> LaundryAmounts.cents("9223372036854775808"));
        rejects(() -> LaundryAmounts.cents(null));
        rejects(() -> LaundryAmounts.validate(50, 100, 0));
        rejects(() -> LaundryAmounts.validate(400, 50, 400));
        System.out.println("LaundryAmounts: " + passed + " passed");
    }
}
