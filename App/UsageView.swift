import SwiftUI

struct UsageView: View {
    @ObservedObject var usage = UsageStore.shared
    @AppStorage("costModel") private var costModel = "sonnet"

    var body: some View {
        let all = usage.all
        PageScaffold(title: "Usage", subtitle: "Every token your local models read and wrote. Counted on this Mac and never sent anywhere.") {
            if all.requests == 0 {
                ContentUnavailableView("No Usage Yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Load a model and use it from an agent, a task or the chat. Every request is counted here from now on."))
                    .frame(maxWidth: .infinity).padding(.vertical, 40).card()
            } else {
                tiles(all)
                ActivityGrid(usage: usage)
                HStack(alignment: .top, spacing: 14) {
                    comparisonCard(all).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card()
                    costCard(all).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card()
                }.fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    Breakdown(title: "By Model", symbol: "cpu", items: all.models).frame(maxWidth: .infinity, alignment: .topLeading).card()
                    Breakdown(title: "By App or Agent", symbol: "terminal", items: all.clients).frame(maxWidth: .infinity, alignment: .topLeading).card()
                }
            }
        }
    }

    private func tiles(_ all: DayUsage) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
            UsageTile(label: "Tokens", value: compactTokens(all.total),
                 detail: "\(compactTokens(all.prompt)) read · \(compactTokens(all.output)) written")
            UsageTile(label: "Requests", value: all.requests.formatted(),
                 detail: days(usage.days.values.filter { $0.total > 0 }.count) + " active")
            UsageTile(label: "Prompt Cache", value: all.prompt > 0 ? "\(min(100, Int((Double(all.cached) / Double(all.prompt) * 100).rounded())))%" : "—",
                 detail: "\(compactTokens(all.cached)) tokens reused")
            UsageTile(label: "Streak", value: days(usage.currentStreak), detail: "longest " + days(usage.longestStreak))
            if let busiest = usage.busiestDay {
                UsageTile(label: "Busiest Day", value: compactTokens(busiest.usage.total),
                     detail: busiest.date.formatted(.dateTime.month(.abbreviated).day().year()))
            }
        }
    }

    private func comparisonCard(_ all: DayUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("That’s Like Reading", systemImage: "books.vertical").font(.headline)
            Text(TokenComparisons.headline(all.total)).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(TokenComparisons.others(all.total), id: \.self) { line in
                Text(line).font(.callout).foregroundStyle(.secondary)
            }
            Text("Counting about 1.3 tokens per English word.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func costCard(_ all: DayUsage) -> some View {
        let model = CloudPrices.models.first { $0.id == costModel } ?? CloudPrices.models[0]
        let cost = CloudPrices.cost(all, model)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("On a Cloud API", systemImage: "cloud").font(.headline)
                Spacer()
                Picker("Model", selection: $costModel) {
                    ForEach(CloudPrices.models) { Text($0.name).tag($0.id) }
                }.labelsHidden().fixedSize()
            }
            Text(cost >= 100 ? "$" + Int(cost.rounded()).formatted() : String(format: "$%.2f", cost))
                .font(.system(size: 34, weight: .bold)).monospacedDigit()
            Text("is what these tokens would have cost on \(model.name). On your Mac they cost nothing beyond electricity.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(String(format: "Anthropic list prices, October 2026: $%.2f input, $%.2f cached input, $%.0f output per million tokens. Tokenizers differ, so this is an estimate.",
                        model.input, model.cachedInput, model.output))
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UsageTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
    }
}

/// A year of daily use as a grid of weeks, like a GitHub contribution graph.
private struct ActivityGrid: View {
    @ObservedObject var usage: UsageStore
    /// The width the card is given, so the 53 weeks always fit it. Read inside a GeometryReader, which takes the
    /// width it is offered whatever its content measures: measuring the grid's own frame fed the cells' size back
    /// into it, so once the cells had grown for a wide window they never shrank, and in a narrower window the grid
    /// pushed the whole page (sidebar included) off the left edge.
    @State private var width: CGFloat = 800
    private let gap: CGFloat = 3, labelWidth: CGFloat = 26
    private func cellSize(for width: CGFloat) -> CGFloat { max(6, min(16, (width - labelWidth - gap * 53) / 53)) }
    private var cell: CGFloat { cellSize(for: width) }
    private let calendar = Calendar.current
    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    var body: some View {
        let weeks = self.weeks
        let shown = weeks.joined().compactMap { $0 }.map { usage.usage(on: $0)?.total ?? 0 }
        let used = shown.filter { $0 > 0 }.sorted()
        let year = shown.reduce(0, +)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(compactTokens(year)) tokens in the last year").font(.headline)
                Spacer()
                legend
            }
            GeometryReader { proxy in
                let cell = cellSize(for: proxy.size.width)
                VStack(alignment: .leading, spacing: 6) {
                    monthLabels(weeks, cell: cell)
                    HStack(alignment: .top, spacing: gap) {
                        weekdayLabels(cell: cell)
                        ForEach(weeks.indices, id: \.self) { index in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { row in
                                    if let date = weeks[index][row] {
                                        let day = usage.usage(on: date)
                                        RoundedRectangle(cornerRadius: 2.5)
                                            .fill(color(Heatmap.level(day?.total ?? 0, among: used)))
                                            .frame(width: cell, height: cell)
                                            .help(tooltip(date, day))
                                    } else {
                                        Color.clear.frame(width: cell, height: cell)
                                    }
                                }
                            }
                        }
                    }
                }
                .preference(key: WidthKey.self, value: proxy.size.width)
            }
            // The reader's height follows the cells, which follow the width it last reported.
            .frame(height: 10 + 6 + 7 * cell + 6 * gap)
            .onPreferenceChange(WidthKey.self) { width = $0 }
        }.card()
    }

    /// 53 columns of 7 days, oldest first, ending with the current week; future days are nil.
    private var weeks: [[Date?]] {
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = calendar.date(byAdding: .weekOfYear, value: -52, to: thisWeek)!
        return (0..<53).map { week in
            (0..<7).map { day in
                let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                return date > today ? nil : date
            }
        }
    }


    private func color(_ level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.07) : Color.green.opacity([0, 0.3, 0.5, 0.75, 1][level])
    }

    private func tooltip(_ date: Date, _ day: DayUsage?) -> String {
        let label = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        guard let day, day.total > 0 else { return "\(label): no use" }
        return "\(label): \(compactTokens(day.total)) tokens in \(day.requests) requests"
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").font(.caption2).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(color($0)).frame(width: 10, height: 10) }
            Text("More").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func weekdayLabels(cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            // Mon, Wed and Fri, as on GitHub, wherever the week starts in this locale.
            ForEach(0..<7, id: \.self) { row in
                let weekday = (calendar.firstWeekday - 1 + row) % 7   // 0 is Sunday
                Text([1, 3, 5].contains(weekday) ? calendar.shortWeekdaySymbols[weekday] : "")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .frame(width: labelWidth, height: cell, alignment: .leading)
            }
        }
    }

    private func monthLabels(_ weeks: [[Date?]], cell: CGFloat) -> some View {
        HStack(spacing: gap) {
            Color.clear.frame(width: labelWidth, height: 10)
            ForEach(weeks.indices, id: \.self) { index in
                let first = weeks[index].compactMap { $0 }.first
                // A month's name sits over its first week; none in the last two columns, where it would be cut off.
                let starts = index < weeks.count - 2 && (first.map { calendar.component(.day, from: $0) <= 7 } ?? false)
                Text(starts ? first!.formatted(.dateTime.month(.abbreviated)) : "")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize().frame(width: cell, alignment: .leading)
            }
        }
    }
}

private struct Breakdown: View {
    let title: String
    let symbol: String
    let items: [String: Int]

    var body: some View {
        let ordered = items.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let sorted: [(key: String, value: Int)] = ordered.count <= 6 ? ordered.map { ($0.key, $0.value) }
            : ordered.prefix(5).map { ($0.key, $0.value) } + [("\(ordered.count - 5) others", ordered.dropFirst(5).reduce(0) { $0 + $1.value })]
        let top = max(1, sorted.map(\.value).max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            if sorted.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sorted, id: \.key) { name, tokens in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(compactTokens(tokens)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Color.accentColor.opacity(0.55))
                            .frame(width: max(4, proxy.size.width * CGFloat(tokens) / CGFloat(top)), height: 4)
                    }.frame(height: 4)
                }
            }
        }
    }
}
