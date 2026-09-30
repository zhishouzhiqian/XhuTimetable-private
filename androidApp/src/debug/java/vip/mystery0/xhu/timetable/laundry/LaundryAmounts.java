package vip.mystery0.xhu.timetable.laundry;

import java.math.BigDecimal;

/** 服务端整数分金额；拒绝舍入、溢出和互相矛盾的报价。 */
final class LaundryAmounts {
    static long cents(Object value) {
        if (value == null) throw new IllegalArgumentException();
        long amount = new BigDecimal(value.toString()).longValueExact();
        if (amount < 0) throw new IllegalStateException("QUOTE_AMOUNT_INVALID");
        return amount;
    }
    static void validate(long total, long discount, long pay) {
        if (total < 0 || discount < 0 || pay < 0 || discount > total || pay != total - discount)
            throw new IllegalStateException("QUOTE_AMOUNT_INVALID");
    }
    static String yuan(long cents) { return BigDecimal.valueOf(cents, 2).toPlainString(); }
}
