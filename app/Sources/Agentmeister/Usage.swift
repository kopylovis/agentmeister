import Charts
import SwiftUI

struct UsageData: Decodable {
    struct Project: Decodable, Identifiable {
        let name: String
        let home: String
        let sessions: Int
        let active: Double
        let tokens: [Int]
        var id: String { name }
    }

    struct Model: Decodable, Identifiable {
        let name: String
        let sessions: Int
        let tokens: [Int]
        var id: String { name }
    }

    struct Heavy: Decodable, Identifiable {
        let id: String
        let title: String
        let project: String
        let active: Double
        let last: Double?
        let total: Int
        let output: Int
    }

    struct Day: Decodable {
        let day: String
        let active: Double
    }

    let days: Int
    let since: Double?
    let sessions: Int
    let active: Double
    let requests: Int
    let tokens: [Int]
    let projects: [Project]
    let models: [Model]
    let heavy: [Heavy]
    let daily: [Day]
}

extension Backend {
    func usage(days: Int) async -> UsageData? {
        await Self.json(["app-state", "usage", String(days)])
    }
}

extension L {
    /// 1.4 млрд, 552 тыс., 1.4B, 552K.
    func tokens(_ n: Int) -> String {
        let v = Double(n)
        if v >= 1e9 { return String(format: "%.1f", v / 1e9) + t(" млрд", "B") }
        if v >= 1e6 { return String(format: v >= 1e8 ? "%.0f" : "%.1f", v / 1e6) + t(" млн", "M") }
        if v >= 1e3 { return String(format: "%.0f", v / 1e3) + t(" тыс.", "K") }
        return "\(n)"
    }

    /// 10 ч 23 мин, 10 h 23 min.
    func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 60 { return t("\(m) мин", "\(m) min") }
        return t("\(m / 60) ч \(m % 60) мин", "\(m / 60) h \(m % 60) min")
    }
}

/// Окно "Статистика": то же, что agentmeister usage, с графиками.
struct UsageView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow
    @AppStorage("usageDays") private var days = 7
    @State private var data: UsageData?
    @State private var loading = false
    @State private var hoverDay: Date?

    var l: L { L(backend.state.lang) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let data {
                    tiles(data)
                    HStack(alignment: .top, spacing: 16) {
                        dailyChart(data)
                        projectChart(data)
                    }
                    projectTable(data)
                    heavyList(data)
                    Text(l.t("Без долларов: на подписке важны токены и время. Время считается по паузам короче 5 минут, вместе с субагентами.",
                             "No dollar amounts: on a subscription tokens and time are what matter. Time counts gaps under 5 minutes, subagents included."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ContentUnavailableView(l.t("Нет данных", "No data"), systemImage: "chart.bar")
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(l.t("Период", "Period"), selection: $days) {
                    Text(l.t("7 дней", "7 days")).tag(7)
                    Text(l.t("30 дней", "30 days")).tag(30)
                    Text(l.t("Все время", "All time")).tag(0)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(l.t("Статистика", "Usage"))
        .navigationSubtitle("Claude Code")
        .task(id: days) {
            loading = true
            data = await backend.usage(days: days)
            loading = false
        }
        .onAppear { WindowMemory.set("usage", open: true) }
        .onDisappear { WindowMemory.set("usage", open: false) }
        .frame(minWidth: 820, minHeight: 560)
    }

    private func tiles(_ d: UsageData) -> some View {
        let items: [(String, String, String)] = [
            (l.t("Активное время", "Active time"), l.duration(d.active), l.t("сумма по сессиям", "summed over sessions")),
            (l.t("Сессий", "Sessions"), "\(d.sessions)", l.t("проектов \(d.projects.count)", "\(d.projects.count) projects")),
            (l.t("Запросов к модели", "Model requests"), "\(d.requests)", d.models.map(\.name).joined(separator: ", ")),
            (l.t("Токенов", "Tokens"), l.tokens(d.tokens.reduce(0, +)), l.t("выход ", "output ") + l.tokens(d.tokens.count > 1 ? d.tokens[1] : 0)),
        ]
        return HStack(spacing: 12) {
            ForEach(items, id: \.0) { title, value, sub in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
        }
    }

    /// Дни периода с нулями там, где работы не было, чтобы пропуски были видны.
    private func dayPoints(_ d: UsageData) -> [(Date, Double)] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let values = Dictionary(d.daily.compactMap { item in f.date(from: item.day).map { ($0, item.active / 3600) } },
                                uniquingKeysWith: +)
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        let start: Date
        if d.days > 0 {
            start = cal.date(byAdding: .day, value: -(d.days - 1), to: end) ?? end
        } else {
            start = values.keys.min() ?? end
        }
        var out: [(Date, Double)] = []
        var day = start
        while day <= end {
            out.append((day, values[day] ?? 0))
            day = cal.date(byAdding: .day, value: 1, to: day) ?? end.addingTimeInterval(86400)
        }
        return out
    }

    private func dailyChart(_ d: UsageData) -> some View {
        let points = dayPoints(d)
        let hovered = hoverDay.flatMap { h in points.first { Calendar.current.isDate($0.0, inSameDayAs: h) } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l.t("Активное время по дням", "Active time per day")).font(.headline)
                Spacer()
                if let hovered {
                    Text(hovered.0.formatted(.dateTime.day().month()) + " · " + l.duration(hovered.1 * 3600))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Chart(points, id: \.0) { point in
                BarMark(x: .value("day", point.0, unit: .day), y: .value("h", point.1), width: .ratio(0.6))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .foregroundStyle(Color.accentColor.opacity(hovered == nil || Calendar.current.isDate(point.0, inSameDayAs: hovered!.0) ? 1 : 0.45))
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let h = value.as(Double.self) { Text(l.t("\(Int(h)) ч", "\(Int(h)) h")) } }
                }
            }
            .chartXSelection(value: $hoverDay)
            .frame(height: 200)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func projectChart(_ d: UsageData) -> some View {
        let top = Array(d.projects.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            Text(l.t("По проектам", "By project")).font(.headline)
            Chart(top) { p in
                BarMark(x: .value("h", p.active / 3600), y: .value("project", p.name), height: .ratio(0.55))
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(l.duration(p.active)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { _ in AxisValueLabel() }
            }
            .chartXScale(domain: 0...((top.map { $0.active / 3600 }.max() ?? 1) * 1.35))
            .frame(height: max(200, CGFloat(top.count) * 28))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func projectTable(_ d: UsageData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.t("Проекты", "Projects")).font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text(l.project).gridColumnAlignment(.leading)
                    Text(l.t("Сессий", "Sessions"))
                    Text(l.t("Время", "Time"))
                    Text(l.t("Запросов", "Requests"))
                    Text(l.t("Выход", "Output"))
                    Text(l.t("Чтение кэша", "Cache read"))
                    Text(l.t("Запись в кэш", "Cache write"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(d.projects) { p in
                    GridRow {
                        Text(p.name).fontWeight(.medium)
                        Text("\(p.sessions)")
                        Text(l.duration(p.active))
                        Text("\(p.tokens.count > 4 ? p.tokens[4] : 0)")
                        Text(l.tokens(p.tokens.count > 1 ? p.tokens[1] : 0))
                        Text(l.tokens(p.tokens.count > 2 ? p.tokens[2] : 0))
                        Text(l.tokens(p.tokens.count > 3 ? p.tokens[3] : 0))
                    }
                    .monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func heavyList(_ d: UsageData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.t("Самые тяжелые сессии", "Heaviest sessions")).font(.headline)
            ForEach(d.heavy) { h in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title.isEmpty ? l.untitled : h.title).fontWeight(.medium).lineLimit(1)
                        Text(h.project + " · " + l.duration(h.active) + (h.last.map { " · " + l.ago($0) } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(l.tokens(h.total)).monospacedDigit()
                        Text(l.t("выход ", "output ") + l.tokens(h.output)).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(l.resume) { resume(h) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func resume(_ h: UsageData.Heavy) {
        let session = backend.state.sessions.first { $0.id == h.id }
        let home = session?.cwd ?? ""
        let project = backend.state.projects.first { $0.name == h.project || (!home.isEmpty && (home == $0.path || home.hasPrefix($0.path + "/"))) }
        guard let project else { return }
        workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path, resumeId: h.id))
        openWindow(id: "main")
    }
}

struct UsageToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: String

    var body: some View {
        Button {
            openWindow(id: "usage")
        } label: {
            Label(title, systemImage: "chart.bar.xaxis")
        }
        .help(title + ", ⇧⌘U")
    }
}

struct OpenUsageButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: String

    var body: some View {
        Button(title) { openWindow(id: "usage") }
            .keyboardShortcut("u", modifiers: [.command, .shift])
    }
}
