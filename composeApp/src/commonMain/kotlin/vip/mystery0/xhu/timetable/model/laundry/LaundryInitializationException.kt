package vip.mystery0.xhu.timetable.model.laundry

/** 仅用于整合测试：报告来自原生客户端固定的脱敏初始化检查，不接受普通异常正文。 */
class LaundryInitializationException(val report: String) : IllegalStateException("CAMPUS_INIT_FAILED")
