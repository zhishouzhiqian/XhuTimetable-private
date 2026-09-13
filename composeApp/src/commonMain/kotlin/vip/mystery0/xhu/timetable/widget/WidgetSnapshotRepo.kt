package vip.mystery0.xhu.timetable.widget

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.LocalDate
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.atTime
import kotlinx.datetime.format
import kotlinx.datetime.plus
import vip.mystery0.xhu.timetable.config.store.Formatter
import vip.mystery0.xhu.timetable.config.store.UserStore
import vip.mystery0.xhu.timetable.config.store.getConfigStore
import vip.mystery0.xhu.timetable.model.TodayCourseView
import vip.mystery0.xhu.timetable.model.TodayThingView
import vip.mystery0.xhu.timetable.repository.AggregationRepo
import vip.mystery0.xhu.timetable.repository.CourseColorRepo
import vip.mystery0.xhu.timetable.ui.theme.ColorPool
import vip.mystery0.xhu.timetable.utils.asInstant
import vip.mystery0.xhu.timetable.utils.asLocalDateTime
import vip.mystery0.xhu.timetable.utils.atStartWeek
import vip.mystery0.xhu.timetable.utils.betweenDays
import kotlin.time.Clock
import kotlin.time.Instant

object WidgetSnapshotRepo {
    /** 一次读取本地课程，生成本周及后续四周，不从扩展发起网络登录或同步。 */
    suspend fun generate(): WidgetSnapshot {
        val now = Clock.System.now()
        val users = UserStore.loggedUserList()
        if (users.isEmpty()) {
            return WidgetSnapshot.empty("loggedOut", now.toEpochMilliseconds())
        }
        val multiAccount = getConfigStore { multiAccountMode }
        val mainId = UserStore.getMainUserId()
        val selectedUsers = if (multiAccount) users else
            listOf(users.firstOrNull { it.studentId == mainId } ?: users.first())
        val startDate = getConfigStore { termStartDate }
        val showCustomCourse = getConfigStore { showCustomCourseOnWeek }
        val showCustomThing = getConfigStore { showCustomThing }
        val view = AggregationRepo.fetchAggregationMainPage(
            forceLoadFromCloud = false,
            forceLoadFromLocal = true,
            showCustomCourse = showCustomCourse,
            showCustomThing = showCustomThing,
            users = selectedUsers,
        )
        val colors = CourseColorRepo.getRawCourseColorList()
        return withContext(Dispatchers.Default) {
            build(now, startDate, view.todayViewList, view.todayThingList, colors)
        }
    }

    /** 输入视图保持不变，便于同一批数据计算不同日期及验证边界。 */
    internal fun build(
        now: Instant,
        termStartDate: LocalDate,
        courses: List<TodayCourseView>,
        things: List<TodayThingView>,
        colors: Map<String, Color>,
    ): WidgetSnapshot {
        val firstDate = now.asLocalDateTime().date.atStartWeek()
        val days = (0 until 35).map { offset ->
            val date = firstDate.plus(offset, DateTimeUnit.DAY)
            val week = weekOf(termStartDate, date)
            val courseItems = courseItems(date, week, courses, colors)
            val thingItems = things.filter {
                it.showOnDay(date.atStartOfDayIn(Formatter.ZONE_CHINA))
            }.map { thing ->
                val start = thing.startTime.asLocalDateTime()
                val end = thing.endTime.asLocalDateTime()
                val remainingDays = betweenDays(date, start.date)
                val timeText = when {
                    thing.saveAsCountDown -> "还剩${remainingDays}天"
                    thing.allDay -> "全天"
                    else -> "${start.time.format(Formatter.TIME_NO_SECONDS)}–${end.time.format(Formatter.TIME_NO_SECONDS)}"
                }
                WidgetSnapshotItem(
                    title = thing.title,
                    location = thing.location,
                    startMillis = thing.startTime.toEpochMilliseconds(),
                    endMillis = thing.endTime.toEpochMilliseconds(),
                    startPeriod = 0,
                    endPeriod = 0,
                    colorArgb = thing.color.toArgb().toLong() and 0xFFFFFFFFL,
                    timeText = timeText,
                    kind = "thing",
                )
            }
            WidgetSnapshotDay(
                date = date.toString(),
                week = week,
                items = (courseItems + thingItems).sortedBy { it.startMillis },
            )
        }
        return WidgetSnapshot(
            generatedAtMillis = now.toEpochMilliseconds(),
            validUntilMillis = firstDate.plus(35, DateTimeUnit.DAY)
                .atStartOfDayIn(Formatter.ZONE_CHINA).toEpochMilliseconds(),
            state = "ready",
            days = days,
        )
    }

    internal fun weekOf(termStartDate: LocalDate, date: LocalDate): Int {
        val days = betweenDays(termStartDate, date)
        // 开学前统一显示第零周，开学后与主课表按开学日计算周数一致。
        return if (days < 0) 0 else (days / 7 + 1).toInt()
    }

    private fun courseItems(
        date: LocalDate,
        week: Int,
        courses: List<TodayCourseView>,
        colors: Map<String, Color>,
    ): List<WidgetSnapshotItem> {
        val matching = courses.filter { week > 0 && week in it.weekList && it.day == date.dayOfWeek }
            .sortedBy { it.startDayTime }
        val merged = ArrayList<TodayCourseView>()
        matching.groupBy { it.user.studentId }.values.forEach { userCourses ->
            var last: TodayCourseView? = null
            userCourses.forEach { original ->
                val course = original.copy().also { it.generateKey() }
                val previous = last
                if (previous != null && previous.key == course.key &&
                    previous.endDayTime == course.startDayTime - 1
                ) {
                    previous.endDayTime = course.endDayTime
                    previous.endTime = course.endTime
                } else {
                    merged.add(course)
                    last = course
                }
            }
        }
        return merged.map { course ->
            val color = colors[course.courseName] ?: ColorPool.hash(course.courseName)
            WidgetSnapshotItem(
                title = course.courseName,
                location = course.location,
                startMillis = date.atTime(course.startTime).asInstant().toEpochMilliseconds(),
                endMillis = date.atTime(course.endTime).asInstant().toEpochMilliseconds(),
                startPeriod = course.startDayTime,
                endPeriod = course.endDayTime,
                colorArgb = color.toArgb().toLong() and 0xFFFFFFFFL,
                timeText = "${course.startTime.format(Formatter.TIME_NO_SECONDS)}–${course.endTime.format(Formatter.TIME_NO_SECONDS)}",
                kind = "course",
            )
        }
    }
}
