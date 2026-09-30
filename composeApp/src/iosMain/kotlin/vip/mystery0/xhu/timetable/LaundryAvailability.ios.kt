package vip.mystery0.xhu.timetable

import vip.mystery0.xhu.timetable.laundry.IosLaundryRuntime

actual val laundryServiceEnabled: Boolean get() = IosLaundryRuntime.available
