import SwiftUI
import WidgetKit

struct TodayWidgetView: View {
    let entry: TimetableEntry
    @Environment(\.widgetFamily) private var family

    private var day: WidgetDay? { entry.snapshot?.day(at: entry.date) }
    private var items: [WidgetCourseItem] { day?.remainingItems(at: entry.date) ?? [] }
    private var limit: Int { family == .systemSmall ? 1 : (family == .systemMedium ? 3 : 7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(family == .systemSmall ? "下一节课" : "今日课程").font(.headline)
                Spacer(minLength: 2)
                if let week = day?.week, week > 0 {
                    Text("第\(week)周").font(.caption2).foregroundColor(.secondary)
                }
            }
            if let message = entry.snapshot?.message(at: entry.date) ?? (entry.snapshot == nil ? "打开西瓜课表同步课程" : nil) {
                WidgetEmptyView(text: message)
            } else {
                let shown = family == .systemSmall ? items.filter { $0.kind == "course" } : items
                if shown.isEmpty {
                    WidgetEmptyView(text: day?.items.contains(where: { $0.kind == "course" }) == true ? "今日课程已结束" : "今天没有课程，享受自由时光")
                } else if family == .systemSmall, let item = shown.first {
                    smallCourse(item)
                } else {
                    ForEach(Array(shown.prefix(limit).enumerated()), id: \.offset) { _, item in
                        courseRow(item)
                    }
                    Spacer(minLength: 0)
                    if shown.count > limit {
                        Text("还有 \(shown.count - limit) 项，打开应用查看")
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func smallCourse(_ item: WidgetCourseItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
            Text(item.location).font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Text(item.timeText).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            Text(item.startDate <= entry.date ? "正在上课" : "即将开始")
                .font(.caption2).foregroundColor(item.color)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func courseRow(_ item: WidgetCourseItem) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(1)
                Text(item.location.isEmpty ? (item.kind == "thing" ? "自定义事项" : "课程") : item.location)
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(item.timeText).font(.caption2).multilineTextAlignment(.trailing).lineLimit(2)
        }.frame(maxHeight: 40)
    }
}
