import SwiftUI

struct WeekWidgetView: View {
    let entry: TimetableEntry
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本周课表").font(.headline)
                Spacer()
                if let week = entry.snapshot?.day(at: entry.date)?.week, week > 0 {
                    Text("第\(week)周").font(.caption).foregroundColor(.secondary)
                }
            }
            if let message = entry.snapshot?.message(at: entry.date) ?? (entry.snapshot == nil ? "打开西瓜课表同步课程" : nil) {
                WidgetEmptyView(text: message)
            } else if let snapshot = entry.snapshot {
                let days = snapshot.week(at: entry.date)
                if days.allSatisfy({ $0.blocks.isEmpty }) {
                    WidgetEmptyView(text: "本周暂无课程")
                } else {
                    grid(days)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func grid(_ days: [WidgetDay]) -> some View {
        GeometryReader { geometry in
            let header: CGFloat = 27
            let rowHeight = max(1, (geometry.size.height - header) / 11)
            HStack(alignment: .top, spacing: 2) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: header)
                    ForEach(1...11, id: \.self) { period in
                        Text("\(period)").font(.system(size: 9)).foregroundColor(.secondary)
                            .frame(height: rowHeight)
                    }
                }.frame(width: 12)
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Text(weekdays[index]).font(.system(size: 10, weight: .semibold))
                            Text(String(day.date.suffix(2))).font(.system(size: 9))
                        }
                        .foregroundColor(day.date == WidgetSnapshot.dateKey(entry.date) ? .green : .secondary)
                        .frame(height: header)
                        GeometryReader { column in
                            ZStack(alignment: .topLeading) {
                                ForEach(0..<11, id: \.self) { row in
                                    Rectangle().fill(Color.secondary.opacity(0.10)).frame(height: 0.5)
                                        .offset(y: CGFloat(row) * rowHeight)
                                }
                                ForEach(Array(day.blocks.enumerated()), id: \.offset) { _, block in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(block.item.title).font(.system(size: 9, weight: .medium)).lineLimit(3)
                                        if !block.item.location.isEmpty {
                                            Text(block.item.location).font(.system(size: 8)).lineLimit(2)
                                        }
                                        if block.count > 1 { Text("+\(block.count - 1)").font(.system(size: 8)) }
                                    }
                                    .padding(2)
                                    .frame(width: column.size.width, height: max(1, CGFloat(block.end - block.start + 1) * rowHeight - 2), alignment: .topLeading)
                                    .background(block.item.color.opacity(0.20))
                                    .cornerRadius(4)
                                    .clipped()
                                    .offset(y: CGFloat(block.start - 1) * rowHeight + 1)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }
}
