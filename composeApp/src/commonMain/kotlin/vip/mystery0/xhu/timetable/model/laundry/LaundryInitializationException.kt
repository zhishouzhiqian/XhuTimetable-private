package vip.mystery0.xhu.timetable.model.laundry

/** 仅用于整合测试：报告来自原生客户端固定的脱敏初始化检查，不接受普通异常正文。 */
class LaundryInitializationException(val report: String) : IllegalStateException("CAMPUS_INIT_FAILED")

/** 付款阶段只传递固定阶段与已脱敏的 HTTP/业务码，不展示业务正文。 */
class LaundryPaymentException(val report: String) : IllegalStateException("CAMPUS_PAYMENT_FAILED")
