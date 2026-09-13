import Foundation

/// 两个 Target 共享的快照协议；不包含账号或网络凭据。
struct WidgetSnapshot: Codable {
    let version: Int
    let generatedAtMillis: Int64
    let validUntilMillis: Int64
    let state: String
    let days: [WidgetDay]

    static let appGroup = "group.vip.mystery0.xhu.timetable"
    static let fileName = "timetable-widget.json"

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }

    static func dateKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func decode(_ data: Data) throws -> WidgetSnapshot {
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        guard snapshot.version == 1,
              ["ready", "loggedOut", "unavailable"].contains(snapshot.state),
              snapshot.days.count <= 70 else {
            throw SnapshotError.unsupportedFormat
        }
        return snapshot
    }

    enum SnapshotError: Error { case unsupportedFormat }

    var expiresAt: Date { Date(timeIntervalSince1970: Double(validUntilMillis) / 1000) }

    func day(at date: Date) -> WidgetDay? {
        days.first { $0.date == Self.dateKey(date) }
    }

    func week(at date: Date) -> [WidgetDay] {
        let calendar = Self.calendar
        let weekday = calendar.component(.weekday, from: date)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: calendar.startOfDay(for: date))!
        return (0..<7).map { offset in
            let dayDate = calendar.date(byAdding: .day, value: offset, to: monday)!
            return day(at: dayDate) ?? WidgetDay(date: Self.dateKey(dayDate), week: 0, items: [])
        }
    }

    func message(at date: Date) -> String? {
        if state == "loggedOut" { return "打开西瓜课表登录账号" }
        if state != "ready" { return "打开西瓜课表同步课程" }
        if date >= expiresAt || day(at: date) == nil { return "课表已过期，打开应用更新" }
        return nil
    }

    /// 提前提供两天内的午夜及上下课节点，系统延迟重载时仍有后续条目。
    func timelineDates(from now: Date) -> [Date] {
        guard message(at: now) == nil else { return [now] }
        let end = min(Self.calendar.date(byAdding: .day, value: 2, to: now)!, expiresAt)
        var dates: Set<Date> = [now, end]
        var midnight = Self.calendar.date(byAdding: .day, value: 1, to: Self.calendar.startOfDay(for: now))!
        while midnight <= end {
            dates.insert(midnight)
            midnight = Self.calendar.date(byAdding: .day, value: 1, to: midnight)!
        }
        for day in days {
            for item in day.items {
                for date in [item.startDate, item.endDate] where date > now && date <= end {
                    dates.insert(date)
                }
            }
        }
        return dates.sorted()
    }
}

struct WidgetDay: Codable {
    let date: String
    let week: Int
    let items: [WidgetCourseItem]

    func remainingItems(at date: Date) -> [WidgetCourseItem] {
        items.filter { $0.endDate > date }.sorted { $0.startMillis < $1.startMillis }
    }

    /// 将重叠课程划为不重叠的节次块，避免周课表文字相互覆盖。
    var blocks: [WidgetWeekBlock] {
        let courses = items.filter { $0.kind == "course" && $0.startPeriod >= 1 && $0.endPeriod <= 11 }
        var result: [WidgetWeekBlock] = []
        var previous: [Int] = []
        for period in 1...11 {
            let indices = courses.indices.filter { courses[$0].startPeriod <= period && courses[$0].endPeriod >= period }
            if indices == previous, !indices.isEmpty, let last = result.last {
                result[result.count - 1] = WidgetWeekBlock(start: last.start, end: period, item: last.item, count: last.count)
            } else if let first = indices.first {
                result.append(WidgetWeekBlock(start: period, end: period, item: courses[first], count: indices.count))
            }
            previous = indices
        }
        return result
    }
}

struct WidgetCourseItem: Codable {
    let title: String
    let location: String
    let startMillis: Int64
    let endMillis: Int64
    let startPeriod: Int
    let endPeriod: Int
    let colorArgb: Int64
    let timeText: String
    let kind: String

    var startDate: Date { Date(timeIntervalSince1970: Double(startMillis) / 1000) }
    var endDate: Date { Date(timeIntervalSince1970: Double(endMillis) / 1000) }
}

struct WidgetWeekBlock {
    let start: Int
    let end: Int
    let item: WidgetCourseItem
    let count: Int
}
