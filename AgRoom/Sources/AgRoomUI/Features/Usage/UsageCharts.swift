import Charts
import SwiftUI
import AgRoomCore

struct UsageTrendBucket: Identifiable {
    var id: Date { start }
    let start: Date
    let end: Date
    var input = 0
    var output = 0
}

/// Covers the whole selected interval, with bounded calendar buckets and empty days included.
enum UsageChartData {
    static func trend(_ stats: UsageStats, interval: DateInterval?, now: Date = Date(),
                      calendar: Calendar = .current) -> [UsageTrendBucket] {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let entries = stats.byDay.compactMap { key, value in
            formatter.date(from: key).map { (date: $0, input: value.input, output: value.output) }
        }
        let end = calendar.startOfDay(for: min(now, interval?.end.addingTimeInterval(-0.001) ?? now))
        let start = calendar.startOfDay(for: interval?.start ?? entries.map(\.date).min() ?? end)
        guard start <= end else { return [] }
        let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        let stride = max(1, Int(ceil(Double(count) / 60)))
        var buckets: [UsageTrendBucket] = []
        for offset in Swift.stride(from: 0, to: count, by: stride) {
            guard let lower = calendar.date(byAdding: .day, value: offset, to: start),
                  let upper = calendar.date(byAdding: .day, value: min(count, offset + stride), to: start) else { continue }
            buckets.append(UsageTrendBucket(start: lower, end: upper))
        }
        for entry in entries where entry.date >= start && entry.date <= end {
            let index = (calendar.dateComponents([.day], from: start, to: entry.date).day ?? 0) / stride
            guard buckets.indices.contains(index) else { continue }
            buckets[index].input += entry.input; buckets[index].output += entry.output
        }
        return buckets
    }
}

private struct UsageChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            Text(L.string(title)).font(MeetTypography.sectionTitle)
            Text(L.string(subtitle)).font(MeetTypography.secondary).foregroundStyle(.secondary)
            content()
        }.padding(MeetSpacing.lg).meetCard()
    }
}

struct UsageTrendChart: View {
    let stats: UsageStats
    let interval: DateInterval?
    @State private var selectedDate: Date?
    var body: some View {
        let buckets = UsageChartData.trend(stats, interval: interval)
        UsageChartCard(title: "usage.trend", subtitle: "usage.chart.trend.desc") {
            if stats.totalTokens == 0 || buckets.isEmpty {
                Text(L.string("settings.usage.empty")).foregroundStyle(.secondary)
            } else {
                Chart(buckets) { bucket in
                    let padding = bucket.end.timeIntervalSince(bucket.start) * 0.15
                    RectangleMark(xStart: .value(L.string("usage.request.time"), bucket.start.addingTimeInterval(padding)),
                                  xEnd: .value(L.string("usage.request.time"), bucket.end.addingTimeInterval(-padding)),
                                  yStart: .value("Tokens", 0), yEnd: .value("Tokens", bucket.input))
                        .foregroundStyle(by: .value(L.string("usage.chart.series"), L.string("settings.usage.input")))
                        .accessibilityLabel(AppDate.dateString(from: bucket.start))
                        .accessibilityValue(L.format("usage.total.breakdown", bucket.input.formatted(), bucket.output.formatted()))
                    RectangleMark(xStart: .value(L.string("usage.request.time"), bucket.start.addingTimeInterval(padding)),
                                  xEnd: .value(L.string("usage.request.time"), bucket.end.addingTimeInterval(-padding)),
                                  yStart: .value("Tokens", bucket.input), yEnd: .value("Tokens", bucket.input + bucket.output))
                        .foregroundStyle(by: .value(L.string("usage.chart.series"), L.string("settings.usage.output")))
                }
                .chartXScale(domain: buckets[0].start...buckets[buckets.count - 1].end)
                .chartForegroundStyleScale(domain: [L.string("settings.usage.input"), L.string("settings.usage.output")],
                                           range: [Color.accentColor.opacity(0.45), Color.accentColor])
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXSelection(value: $selectedDate)
                .frame(height: 220)
                .environment(\.locale, Locale(identifier: LanguageManager.shared.activeLanguageCode))
                if let selectedDate, let bucket = buckets.last(where: { $0.start <= selectedDate && selectedDate < $0.end }) {
                    Text(AppDate.dateString(from: bucket.start) + " – " + AppDate.dateString(from: bucket.end.addingTimeInterval(-1)) + " · "
                         + L.format("usage.total.breakdown", bucket.input.formatted(), bucket.output.formatted()))
                        .font(MeetTypography.secondary).monospacedDigit()
                } else {
                    Text(L.string("usage.chart.select")).font(MeetTypography.secondary).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct UsageModelChart: View {
    let stats: UsageStats
    var body: some View {
        let groups = Array(stats.modelGroups.filter { $0.input + $0.output > 0 }.prefix(6))
        UsageChartCard(title: "usage.chart.models", subtitle: "usage.chart.models.desc") {
            if groups.isEmpty {
                Text(L.string("settings.usage.empty")).foregroundStyle(.secondary)
            } else {
                let peak = max(1, groups.map { $0.input + $0.output }.max() ?? 1)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.model.isEmpty ? L.string("usage.model.unknown") : group.model)
                                    .font(MeetTypography.listTitle).lineLimit(1).help(group.model)
                                Text(group.providerName ?? L.string("usage.provider.unknown"))
                                    .font(MeetTypography.secondary).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((group.input + group.output).formatted()).monospacedDigit()
                        }
                        GeometryReader { geometry in
                            HStack(spacing: 0) {
                                Rectangle().fill(Color.accentColor.opacity(0.45))
                                    .frame(width: geometry.size.width * Double(group.input) / Double(peak))
                                Rectangle().fill(Color.accentColor)
                                    .frame(width: geometry.size.width * Double(group.output) / Double(peak))
                            }.clipShape(RoundedRectangle(cornerRadius: 3))
                        }.frame(height: 10)
                        Text(L.format("usage.total.breakdown", group.input.formatted(), group.output.formatted()))
                            .font(MeetTypography.secondary).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct UsageCacheChart: View {
    let stats: UsageStats
    var body: some View {
        UsageChartCard(title: "usage.chart.cache", subtitle: "usage.chart.cache.desc") {
            let rows = [(key: "usage.cache.read", value: stats.totalCacheReadTokens, count: stats.reportedCacheReadRecords),
                        (key: "usage.cache.write", value: stats.totalCacheWriteTokens, count: stats.reportedCacheWriteRecords)]
            let peak = max(1, rows.map(\.value).max() ?? 1)
            ForEach(rows, id: \.key) { row in
                VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                    HStack {
                        Text(L.string(row.key))
                        Spacer()
                        Text(row.count == 0 ? L.string("usage.unreported") : row.value.formatted()).monospacedDigit()
                    }
                    if row.count > 0 { ProgressView(value: Double(row.value), total: Double(peak)) }
                    Text(L.format("usage.report.coverage", row.count, stats.totalTurns))
                        .font(MeetTypography.secondary).foregroundStyle(.secondary)
                }
            }
        }
    }
}
