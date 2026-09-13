package vip.mystery0.xhu.timetable.widget

import androidx.compose.ui.graphics.Color
import kotlinx.datetime.DayOfWeek
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.atTime
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import vip.mystery0.xhu.timetable.config.store.Formatter
import vip.mystery0.xhu.timetable.config.store.User
import vip.mystery0.xhu.timetable.model.Gender
import vip.mystery0.xhu.timetable.model.TodayCourseView
import vip.mystery0.xhu.timetable.model.TodayThingView
import vip.mystery0.xhu.timetable.model.UserInfo
import vip.mystery0.xhu.timetable.utils.asInstant

/** 不依赖额外测试库；测试宿主调用 runChecks()，返回可供 Swift 解码的完整快照。 */
object WidgetSnapshotChecks {
    fun runChecks(): String {
        val termStart = LocalDate(2026, 9, 7)
        val user = User(
            studentId = "PRIVATE_STUDENT_MARKER",
            password = "PRIVATE_PASSWORD_MARKER",
            token = "PRIVATE_TOKEN_MARKER",
            info = UserInfo("", "", Gender.UNKNOWN, 2026, "", "", "", ""),
        )
        val first = TodayCourseView(
            courseName = "高等数学",
            weekList = listOf(1, 3, 5),
            day = DayOfWeek.MONDAY,
            startDayTime = 1,
            endDayTime = 2,
            startTime = LocalTime(8, 0),
            endTime = LocalTime(9, 40),
            location = "四教 101",
            teacher = "教师",
            user = user,
        )
        val next = first.copy(
            startDayTime = 3,
            endDayTime = 4,
            startTime = LocalTime(10, 0),
            endTime = LocalTime(11, 40),
        )
        val separated = first.copy(
            startDayTime = 7,
            endDayTime = 8,
            startTime = LocalTime(16, 0),
            endTime = LocalTime(17, 40),
        )
        val countdown = TodayThingView(
            title = "考试",
            location = "图书馆",
            allDay = false,
            startTime = LocalDate(2026, 9, 9).atTime(9, 0).asInstant(),
            endTime = LocalDate(2026, 9, 9).atTime(11, 0).asInstant(),
            remark = "PRIVATE_REMARK_MARKER",
            color = Color.Red,
            saveAsCountDown = true,
            user = user,
        )
        val snapshot = WidgetSnapshotRepo.build(
            now = termStart.atTime(12, 0).asInstant(),
            termStartDate = termStart,
            courses = listOf(first, next, separated, first.copy(user = user.copy(studentId = "OTHER_USER"))),
            things = listOf(countdown),
            colors = mapOf("高等数学" to Color.Red),
        )
        check(snapshot.days.size == 35)
        check(snapshot.days.first().date == "2026-09-07")
        check(snapshot.days.last().date == "2026-10-11")
        check(snapshot.validUntilMillis == LocalDate(2026, 10, 12)
            .atStartOfDayIn(Formatter.ZONE_CHINA).toEpochMilliseconds())
        val monday = snapshot.days.first()
        val mondayCourses = monday.items.filter { it.kind == "course" }
        check(mondayCourses.size == 3)
        val merged = mondayCourses.first { it.endPeriod == 4 }
        check(merged.startPeriod == 1)
        check(merged.endMillis == termStart.atTime(11, 40).asInstant().toEpochMilliseconds())
        check(merged.colorArgb == 0xFFFF0000L)
        check(first.endDayTime == 2 && first.endTime == LocalTime(9, 40))
        check(snapshot.days[7].items.none { it.kind == "course" })
        check(snapshot.days[14].items.count { it.kind == "course" } == 3)
        check(monday.items.single { it.kind == "thing" }.timeText == "还剩2天")
        check(snapshot.days[3].items.none { it.kind == "thing" })
        check(WidgetSnapshotRepo.weekOf(termStart, LocalDate(2026, 9, 6)) == 0)
        check(WidgetSnapshotRepo.weekOf(termStart, LocalDate(2026, 8, 1)) == 0)
        check(WidgetSnapshotRepo.weekOf(termStart, LocalDate(2026, 9, 13)) == 1)
        check(WidgetSnapshotRepo.weekOf(termStart, LocalDate(2026, 9, 14)) == 2)
        val encoded = snapshot.encode()
        check(!encoded.contains("PRIVATE_") && !encoded.contains("OTHER_USER"))
        val loggedOut = Json.parseToJsonElement(WidgetSnapshot.empty("loggedOut", 1).encode()).jsonObject
        check(loggedOut.getValue("version").toString() == "1")
        check(loggedOut.getValue("days").jsonArray.isEmpty())
        return encoded
    }
}
