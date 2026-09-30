package vip.mystery0.xhu.timetable

// 设备实现与模拟器实现分开，避免同一编译目标出现两个 actual 声明。
actual val isDebug: Boolean
    get() = false
