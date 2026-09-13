import SwiftUI
import WidgetKit
import OSLog

struct TimetableEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct TimetableProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimetableEntry {
        TimetableEntry(date: Date(), snapshot: Self.preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (TimetableEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TimetableEntry(date: Date(), snapshot: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimetableEntry>) -> Void) {
        let now = Date()
        let snapshot = load()
        let dates = snapshot?.timelineDates(from: now) ?? [now]
        let entries = dates.map { TimetableEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 3600))))
    }

    private func load() -> WidgetSnapshot? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup
        ) else { return nil }
        let file = directory.appendingPathComponent(WidgetSnapshot.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try WidgetSnapshot.decode(Data(contentsOf: file))
        } catch {
            Logger(subsystem: "vip.mystery0.xhu.timetable.widgets", category: "Snapshot")
                .error("Failed to read widget snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static var preview: WidgetSnapshot {
        let now = Date()
        let start = WidgetSnapshot.calendar.startOfDay(for: now).addingTimeInterval(14 * 3600)
        let item = WidgetCourseItem(title: "高等数学", location: "四教 A201", startMillis: Int64(start.timeIntervalSince1970 * 1000), endMillis: Int64(start.addingTimeInterval(90 * 60).timeIntervalSince1970 * 1000), startPeriod: 5, endPeriod: 6, colorArgb: 0xFF438B65, timeText: "14:00–15:30", kind: "course")
        return WidgetSnapshot(version: 1, generatedAtMillis: Int64(now.timeIntervalSince1970 * 1000), validUntilMillis: Int64(now.addingTimeInterval(86400).timeIntervalSince1970 * 1000), state: "ready", days: [WidgetDay(date: WidgetSnapshot.dateKey(now), week: 1, items: [item])])
    }
}

struct TodayTimetableWidget: Widget {
    let kind = "TodayTimetableWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimetableProvider()) { entry in
            TodayWidgetView(entry: entry).timetableBackground()
        }
        .configurationDisplayName("今日课程")
        .description("查看下一节课、今日课程和自定义事项。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WeekTimetableWidget: Widget {
    let kind = "WeekTimetableWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimetableProvider()) { entry in
            WeekWidgetView(entry: entry).timetableBackground()
        }
        .configurationDisplayName("本周课表")
        .description("一眼查看周一至周日的课程安排。")
        .supportedFamilies([.systemLarge])
    }
}

@main
struct TimetableWidgets: WidgetBundle {
    var body: some Widget {
        TodayTimetableWidget()
        WeekTimetableWidget()
    }
}

extension View {
    @ViewBuilder
    func timetableBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(for: .widget) { Color(.systemBackground) }
        } else {
            self.padding(12).background(Color(.systemBackground))
        }
    }
}

extension WidgetCourseItem {
    var color: Color {
        let value = UInt32(truncatingIfNeeded: colorArgb)
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct WidgetEmptyView: View {
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar").font(.title2).foregroundColor(.secondary)
            Text(text).font(.caption).multilineTextAlignment(.center).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
