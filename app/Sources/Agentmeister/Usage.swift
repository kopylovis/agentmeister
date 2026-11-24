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

/// Окно "Статистика" по макету Usage.dc.html: то же, что agentmeister usage.
struct UsageView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow
    @AppStorage("usageDays") private var days = 7
    @State private var data: UsageData?
    @State private var loading = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let data {
                    tiles(data)
                    HStack(alignment: .top, spacing: 16) {
                        projectBars(data)
                        heavyList(data)
                    }
                    projectTable(data)
                    Text(l.t("Без долларов, на подписке важны токены и время. Агенты видят тот же отчет через MCP.",
                             "No dollar amounts, on a subscription tokens and time are what matter. Agents get the same report through MCP."))
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.faint)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ContentUnavailableView(l.t("Нет данных", "No data"), systemImage: "chart.bar")
                }
            }
            .padding(24)
        }
        .navigationTitle(l.t("Статистика", "Usage"))
        .task(id: days) {
            loading = true
            data = await backend.usage(days: days)
            loading = false
        }
        .onAppear { WindowMemory.set("usage", open: true) }
        .onDisappear { WindowMemory.set("usage", open: false) }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(l.t("Статистика", "Usage")).font(.system(size: 22, weight: .semibold))
            if let range = rangeText { Text(range).foregroundStyle(Ink.muted) }
            Spacer()
            SegmentedCapsule(selection: $days, options: [(7, l.t("7 дней", "7 days"), nil), (30, l.t("30 дней", "30 days"), nil),
                                                         (0, l.t("Все время", "All time"), nil)])
                .frame(width: 320)
                .accessibilityLabel(l.t("Период", "Period"))
            Picker(l.agent, selection: .constant("claude")) {
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex").disabled(true)
            }
            .labelsHidden()
            .frame(width: 140)
            .help(l.t("Статистика Codex пока не собирается", "Codex usage isn't collected yet"))
        }
    }

    /// "с 18 по 24 ноября" / "Nov 18 to 24".
    private var rangeText: String? {
        guard let since = data?.since else { return nil }
        let start = Date(timeIntervalSince1970: since), end = Date()
        let cal = Calendar.current
        let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
        let f = DateFormatter()
        f.locale = Locale(identifier: l.en ? "en_US" : "ru_RU")
        if l.en {
            f.dateFormat = "MMM d"
            let a = f.string(from: start)
            f.dateFormat = sameMonth ? "d" : "MMM d"
            return a + " to " + f.string(from: end)
        }
        f.dateFormat = sameMonth ? "d" : "d MMMM"
        let a = f.string(from: start)
        f.dateFormat = "d MMMM"
        return "с " + a + " по " + f.string(from: end)
    }

    private func grouped(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: l.en ? "en_US" : "ru_RU")))
    }

    private func tiles(_ d: UsageData) -> some View {
        let total = d.tokens.reduce(0, +)
        let output = d.tokens.count > 1 ? d.tokens[1] : 0
        let cacheRead = d.tokens.count > 2 ? d.tokens[2] : 0
        let tokenNote = total > 0 && Double(cacheRead) / Double(total) > 0.9
            ? l.t("почти все из кэша, выход ", "almost all cache reads, ") + l.tokens(output) + l.t("", " output")
            : l.t("выход ", "output ") + l.tokens(output)
        let items: [(String, String, String)] = [
            (l.t("Активное время", "Active time"), l.duration(d.active), l.t("паузы дольше 5 мин не считаются", "gaps over 5 min don't count")),
            (l.t("Сессий", "Sessions"), "\(d.sessions)", l.t("в \(d.projects.count) проектах", "in \(d.projects.count) projects")),
            (l.t("Запросов к модели", "Model requests"), grouped(d.requests), d.models.map(\.name).joined(separator: ", ")),
            (l.t("Токенов", "Tokens"), l.tokens(total), tokenNote),
        ]
        return HStack(spacing: 12) {
            ForEach(items, id: \.0) { title, value, sub in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12)).foregroundStyle(Ink.muted)
                    Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    Text(sub).font(.system(size: 12)).foregroundStyle(Ink.faint).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
    }

    /// Активное время по проектам горизонтальными полосами: имя, дорожка с полосой, время. Подсказка на строке.
    private func projectBars(_ d: UsageData) -> some View {
        let top = Array(d.projects.prefix(8))
        let maxActive = max(top.map(\.active).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Активное время по проектам", "Active time by project")).font(.system(size: 15, weight: .semibold))
            VStack(spacing: 10) {
                ForEach(top) { p in
                    HStack(spacing: 10) {
                        Text(p.name).font(.system(size: 12)).lineLimit(1).frame(width: 116, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Ink.chip)
                                Capsule().fill(Color.accentColor).frame(width: max(6, geo.size.width * p.active / maxActive))
                            }
                        }
                        .frame(height: 10)
                        Text(l.duration(p.active)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.muted)
                            .frame(width: 84, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .help(p.name + l.t(" · сессий ", " · sessions ") + "\(p.sessions)" + l.t(" · запросов ", " · requests ")
                          + grouped(p.tokens.count > 4 ? p.tokens[4] : 0))
                }
            }
            Text(l.t("Наведи на строку, чтобы увидеть сессии и запросы. Точные числа в таблице ниже.",
                     "Hover a row for sessions and requests. Exact numbers are in the table below."))
                .font(.system(size: 11)).foregroundStyle(Ink.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func heavyList(_ d: UsageData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l.t("Самые тяжелые сессии", "Heaviest sessions")).font(.system(size: 15, weight: .semibold)).padding(.bottom, 4)
            ForEach(d.heavy) { h in
                Button {
                    resume(h)
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.title.isEmpty ? l.untitled : h.title).fontWeight(.medium).lineLimit(1)
                            Text([h.project, h.last.map { shortDate($0) }, l.duration(h.active)].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Ink.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(l.tokens(h.total)).monospacedDigit()
                            Text(l.t("выход ", "output ") + l.tokens(h.output)).font(.system(size: 11)).foregroundStyle(Ink.muted)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Ink.card))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l.t("Продолжить во вкладке", "Resume in a tab"))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// "24.11" / "Nov 24".
    private func shortDate(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: l.en ? "en_US" : "ru_RU")
        f.dateFormat = l.en ? "MMM d" : "dd.MM"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func projectTable(_ d: UsageData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l.t("По проектам", "By project")).font(.system(size: 15, weight: .semibold))
            VStack(spacing: 0) {
                tableRow([l.project, l.t("Сессий", "Sessions"), l.t("Время", "Time"), l.t("Запросов", "Requests"), l.t("Выход", "Output"),
                          l.t("Чтение кэша", "Cache read"), l.t("Запись в кэш", "Cache write")], header: true)
                ForEach(d.projects) { p in
                    Rectangle().fill(Ink.hairline).frame(height: 1)
                    tableRow([p.name, "\(p.sessions)", l.duration(p.active), grouped(p.tokens.count > 4 ? p.tokens[4] : 0),
                              l.tokens(p.tokens.count > 1 ? p.tokens[1] : 0), l.tokens(p.tokens.count > 2 ? p.tokens[2] : 0),
                              l.tokens(p.tokens.count > 3 ? p.tokens[3] : 0)], header: false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell)
                    .fontWeight(!header && index == 0 ? .medium : .regular)
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
                    .lineLimit(1)
            }
        }
        .font(.system(size: header ? 11 : 12))
        .foregroundStyle(header ? Ink.faint : Ink.text)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, header ? 8 : 9)
    }

    private func resume(_ h: UsageData.Heavy) {
        let session = backend.state.sessions.first { $0.id == h.id }
        let home = session?.cwd ?? ""
        let project = backend.state.projects.first { $0.name == h.project || (!home.isEmpty && (home == $0.path || home.hasPrefix($0.path + "/"))) }
        guard let project else { return }
        workspace.open(LaunchSpec.resume(h.id, cwd: session?.cwd, project: project))
        openWindow(id: "main")
    }
}

struct OpenUsageButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: String

    var body: some View {
        Button(title) { openWindow(id: "usage") }
            .shortcut(.usage)
    }
}
