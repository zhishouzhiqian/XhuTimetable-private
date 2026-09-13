import Foundation

// 独立可执行测试：只依赖 Foundation，可在 macOS CI 上直接使用 swiftc。
func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
func millis(_ value: Date) -> Int64 { Int64(value.timeIntervalSince1970 * 1000) }
let now = date("2026-09-13T15:30:00Z") // 中国时间周日 23:30
let monday = date("2026-09-13T16:00:00Z")
let courseStart = date("2026-09-14T00:00:00Z")
let courseEnd = date("2026-09-14T01:40:00Z")
let expires = date("2026-09-20T16:00:00Z")

let course: [String: Any] = [
    "title": "高等数学", "location": "四教 A201", "startMillis": millis(courseStart),
    "endMillis": millis(courseEnd), "startPeriod": 1, "endPeriod": 2,
    "colorArgb": Int64(0xFF438B65), "timeText": "08:00–09:40", "kind": "course",
]
let payload: [String: Any] = [
    "version": 1, "generatedAtMillis": millis(now), "validUntilMillis": millis(expires), "state": "ready",
    "days": [
        ["date": "2026-09-13", "week": 1, "items": []],
        ["date": "2026-09-14", "week": 2, "items": [course]],
        ["date": "2026-09-20", "week": 2, "items": []],
    ],
]
let snapshot = try WidgetSnapshot.decode(JSONSerialization.data(withJSONObject: payload))
precondition(snapshot.day(at: now)?.week == 1)
precondition(snapshot.day(at: monday)?.week == 2)
precondition(snapshot.week(at: now).first?.date == "2026-09-07")
precondition(snapshot.week(at: monday).first?.date == "2026-09-14")
precondition(snapshot.week(at: monday).last?.date == "2026-09-20")
precondition(snapshot.message(at: expires) != nil)
precondition(snapshot.message(at: monday) == nil)
precondition(snapshot.message(at: date("2026-09-15T00:00:00Z")) != nil)

let dates = snapshot.timelineDates(from: now)
precondition(dates.contains(monday))
precondition(dates.contains(courseStart))
precondition(dates.contains(courseEnd))
precondition(dates == dates.sorted() && Set(dates).count == dates.count)
let day = snapshot.day(at: monday)!
precondition(day.remainingItems(at: courseStart).count == 1)
precondition(day.remainingItems(at: courseEnd).isEmpty)
precondition(day.blocks.count == 1 && day.blocks[0].start == 1 && day.blocks[0].end == 2)
precondition(day.items[0].colorArgb == 0xFF438B65)

let conflictingDay = WidgetDay(date: day.date, week: day.week, items: day.items + day.items)
precondition(conflictingDay.blocks.count == 1 && conflictingDay.blocks[0].count == 2)
let loggedOut = WidgetSnapshot(version: 1, generatedAtMillis: millis(now), validUntilMillis: millis(now), state: "loggedOut", days: [])
precondition(loggedOut.message(at: now) == "打开西瓜课表登录账号")
precondition(loggedOut.timelineDates(from: now) == [now])

var futurePayload = payload
futurePayload["version"] = 2
do {
    _ = try WidgetSnapshot.decode(JSONSerialization.data(withJSONObject: futurePayload))
    fatalError("Unknown snapshot version was accepted")
} catch WidgetSnapshot.SnapshotError.unsupportedFormat { }

// 可传入 Kotlin 测试导出的真实 JSON，校验两种语言间的序列化契约。
if CommandLine.arguments.count > 1 {
    let fixture = try WidgetSnapshot.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    precondition(fixture.state == "ready" && fixture.days.count == 35)
    precondition(fixture.days.contains { !$0.items.isEmpty })
}
print("Widget snapshot and timeline checks passed")
