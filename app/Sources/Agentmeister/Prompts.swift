import SwiftTerm
import SwiftUI

/// Строка отправленного запроса в прокрутке терминала.
struct PromptMark: Equatable {
    /// Сквозной номер строки буфера, как absoluteRow у снимков SwiftTerm: не меняется при прокрутке.
    let row: Int
    let text: String
}

/// Что показать в закрепленной полосе: запрос, его номер из всех и сдвиг вверх, когда снизу подъезжает следующий.
struct StickyPrompt: Equatable {
    let mark: PromptMark
    let index: Int
    let total: Int
    let offset: CGFloat
    /// Когда запрос отправлен, из переписки сессии. Nil, если строку не удалось сопоставить.
    let date: Date?
}

/// Запрос из переписки сессии: текст и время отправки.
struct SessionPrompt: Equatable {
    let text: String
    let date: Date
    let firstLine: String
    let renderedFirstLine: String?

    init(text: String, date: Date, agent: LaunchSpec.Agent) {
        self.text = text
        self.date = date
        let line = String(text.prefix(while: { !$0.isNewline }))
        firstLine = Self.normalized(line)
        if agent == .codex, line.contains(where: { "`*_[]#>".contains($0) }),
           let markdown = try? AttributedString(markdown: line) {
            renderedFirstLine = Self.normalized(String(markdown.characters))
        } else {
            renderedFirstLine = nil
        }
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    func matches(_ shown: String, agent: LaunchSpec.Agent) -> Bool {
        guard !firstLine.isEmpty, !shown.isEmpty else { return false }
        return firstLine.hasPrefix(shown) || renderedFirstLine?.hasPrefix(shown) == true
            || (agent == .claude && shown.hasPrefix(firstLine))
    }
}

/// Строка списка запросов: запрос из переписки и его строка в выводе, если она еще в прокрутке терминала.
struct PromptEntry: Identifiable, Equatable {
    let id: Int
    let text: String
    let date: Date?
    let mark: PromptMark?
}

/// Результат прохода по буферу.
struct PromptScan: Equatable {
    var marks: [PromptMark]
    /// Сквозной номер верхней видимой строки.
    let top: Int
    /// Сквозной номер первой строки, которую терминал еще хранит. scrollTo(row:) считает от нее.
    let linesTop: Int
    let rows: Int
    /// Сквозной номер строки сразу за последней: вся высота буфера это bottom - linesTop.
    let bottom: Int
}

/// Ссылка на терминал для фонового потока. Снимки SwiftTerm берут его замок сами и безопасны из любого потока.
struct TerminalRef: @unchecked Sendable {
    let view: TerminalView
}

/// Запросы вкладки. Прокрутка выше живого экрана больше не меняется, поэтому ее строки читаются один раз, порциями,
/// а живой экран перечитывается при каждом проходе. Смена ширины перестраивает переносы и сбрасывает все.
final class PromptIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var cols = 0
    private var scanned = 0
    private var history: [PromptMark] = []

    func update(_ ref: TerminalRef, agent: LaunchSpec.Agent) -> PromptScan? {
        lock.lock()
        defer { lock.unlock() }
        let view = ref.view
        guard view.terminalInputStateSnapshot()?.isAlternateBuffer == false,
              let viewport = view.terminalContentSnapshot(region: .viewport), viewport.bufferKind == .normal,
              let origin = view.terminalContentSnapshot(region: .rows(0..<0)) else { return nil }
        let linesTop = origin.capturedRange.lowerBound
        let liveTop = viewport.liveTopRow
        let rows = viewport.dimensions.rows
        // другая ширина или очищенная прокрутка: номера строк стали другими
        if viewport.dimensions.cols != cols || liveTop < scanned {
            cols = viewport.dimensions.cols
            scanned = 0
            history = []
        }
        scanned = max(scanned, linesTop)
        if let first = history.first, first.row < linesTop {
            history.removeAll { $0.row < linesTop }
        }
        let mark = { (row: TerminalContentRowSnapshot) in Self.mark(row, agent: agent) }
        while scanned < liveTop {
            let end = min(scanned + 600, liveTop)
            guard let chunk = view.terminalContentSnapshot(region: .rows(scanned..<end)) else { break }
            history += chunk.rows.compactMap(mark)
            scanned = end
        }
        let live = view.terminalContentSnapshot(region: .rows(liveTop..<(liveTop + rows)))?.rows.compactMap(mark) ?? []
        return PromptScan(marks: history + live, top: viewport.capturedRange.lowerBound, linesTop: linesTop, rows: rows,
                          bottom: liveTop + rows)
    }

    static func mark(_ row: TerminalContentRowSnapshot, agent: LaunchSpec.Agent) -> PromptMark? {
        guard !row.isWrapped, let first = row.cells.firstIndex(where: { !$0.isBlank }) else { return nil }
        let cell = row.cells[first]
        switch agent {
        case .claude:
            guard cell.text == "❯", cell.attribute.bg != .defaultColor, cell.attribute.bg != .defaultInvertedColor else { return nil }
        case .codex:
            // У отправленного текста знак бледный, у диктовки красный. В поле ввода знак без затемнения.
            guard first == 0, cell.text == "›", cell.attribute.style.contains(.bold),
                  cell.attribute.style.contains(.dim) || cell.attribute.fg == .ansi256(code: 1) else { return nil }
        }
        var text = row.text.trimmingCharacters(in: .whitespaces)
        text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        return PromptMark(row: row.absoluteRow, text: text)
    }
}

/// Запросы пользователя из переписки сессии. Переписка растет до мегабайт, поэтому читается только дописанное
/// с прошлого раза. Служебные записи (уведомления фоновых задач, напоминания, прерывания, вывод команд, подписи
/// к картинкам) запросами не считаются.
enum SessionPrompts {
    private final class Cursor {
        var offset: UInt64 = 0
        var prompts: [SessionPrompt] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cursors: [String: Cursor] = [:]
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let service = ["<task-notification", "<system-reminder", "[Request interrupted", "<command-",
                                  "<local-command", "Caveat:", "[Image: source"]

    static func list(_ sessionId: String, agent: LaunchSpec.Agent) -> [SessionPrompt] {
        let path = agent == .codex ? SessionContext.codexFile(sessionId) : SessionContext.file(sessionId)
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        lock.lock()
        defer { lock.unlock() }
        let cursor = cursors[path] ?? Cursor()
        cursors[path] = cursor
        let size = (try? handle.seekToEnd()) ?? 0
        if size < cursor.offset {
            cursor.offset = 0
            cursor.prompts = []
        }
        guard size > cursor.offset else { return cursor.prompts }
        try? handle.seek(toOffset: cursor.offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return cursor.prompts }
        let complete = data[data.startIndex...lastNewline]
        cursor.offset += UInt64(complete.count)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let content = agent == .codex ? codexText(o) : claudeText(o)
            guard let text = content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let date = (o["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            cursor.prompts.append(SessionPrompt(text: text, date: date, agent: agent))
        }
        return cursor.prompts
    }

    static func codexText(_ record: [String: Any]) -> String? {
        guard record["type"] as? String == "event_msg", let event = record["payload"] as? [String: Any] else { return nil }
        switch event["type"] as? String {
        case "user_message":
            return event["message"] as? String
        case "item_completed":
            guard let item = event["item"] as? [String: Any], item["type"] as? String == "UserMessage",
                  let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func claudeText(_ o: [String: Any]) -> String? {
        guard o["type"] as? String == "user", o["isMeta"] as? Bool != true,
              let message = o["message"] as? [String: Any] else { return nil }
        let text: String
        if let plain = message["content"] as? String {
            text = plain
        } else if let blocks = message["content"] as? [[String: Any]],
                  !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return service.contains(where: { trimmed.hasPrefix($0) }) ? nil : trimmed
    }

    /// Свести запросы из переписки со строками в выводе. Идем с конца: последние запросы точно на экране, а самые
    /// старые могли уйти из прокрутки. Строка в выводе это первая строка запроса, иногда обрезанная по ширине.
    static func merge(_ marks: [PromptMark], _ prompts: [SessionPrompt], agent: LaunchSpec.Agent) -> [PromptEntry] {
        var paired: [Int: Int] = [:]   // индекс запроса -> индекс строки
        var i = marks.count - 1
        var j = prompts.count - 1
        while i >= 0 && j >= 0 {
            let shown = SessionPrompt.normalized(marks[i].text).trimmingCharacters(in: CharacterSet(charactersIn: "…"))
            if prompts[j].matches(shown, agent: agent) {
                paired[j] = i
                i -= 1
                j -= 1
            } else if !shown.isEmpty, j > 0,
                      let k = (0..<j).reversed().first(where: { prompts[$0].matches(shown, agent: agent) }) {
                // запросы между ними в выводе не нашлись (ушли с экрана при перерисовке или из другой вкладки): пропускаем
                j = k
            } else {
                // строка в выводе без запроса в переписке: оставим ее без времени
                i -= 1
            }
        }
        var out: [PromptEntry] = []
        var used = Set<Int>()
        for (index, prompt) in prompts.enumerated() {
            let mark = paired[index].map { marks[$0] }
            if let m = paired[index] { used.insert(m) }
            out.append(PromptEntry(id: out.count, text: prompt.text, date: prompt.date, mark: mark))
        }
        if agent == .codex { return out }
        // строки вывода, которых нет в переписке (другая сессия в этой вкладке до перезапуска): по месту в выводе
        for (index, mark) in marks.enumerated() where !used.contains(index) {
            let at = out.firstIndex { $0.mark.map { $0.row > mark.row } ?? false } ?? out.count
            out.insert(PromptEntry(id: 0, text: mark.text, date: nil, mark: mark), at: at)
        }
        return out.enumerated().map { PromptEntry(id: $0.offset, text: $0.element.text, date: $0.element.date, mark: $0.element.mark) }
    }
}

extension TerminalTab {
    /// Высота закрепленной полосы и отступ терминала от верха контейнера (TerminalHost).
    static let stickyHeight: CGFloat = 34
    static let terminalTopInset: CGFloat = 14

    /// Перечитать запросы и пересчитать закрепленную полосу.
    func refreshPrompts() async {
        guard spec.claudeSession || spec.codexSession else {
            if sticky != nil { sticky = nil }
            return
        }
        let ref = TerminalRef(view: view)
        let index = promptIndex
        let sid = sessionId
        let agent = spec.agent
        let (scan, entries) = await Task.detached(priority: .userInitiated) {
            var scan = index.update(ref, agent: agent)
            let prompts = scan == nil ? [] : sid.map { SessionPrompts.list($0, agent: agent) } ?? []
            let entries = SessionPrompts.merge(scan?.marks ?? [], prompts, agent: agent)
            if agent == .codex { scan?.marks = entries.compactMap(\.mark) }
            return (scan, entries)
        }.value
        guard !Task.isCancelled, sessionId == sid else { return }
        if promptScan != scan { promptScan = scan }
        if promptEntries != entries { promptEntries = entries }
        let next = computeSticky()
        if sticky != next { sticky = next }
    }

    /// Закреплен последний запрос, чья строка ушла под полосу. Следующий, подъезжая снизу, выталкивает полосу вверх.
    private func computeSticky() -> StickyPrompt? {
        guard let scan = promptScan, scan.rows > 0, !scan.marks.isEmpty else { return nil }
        let cell = view.bounds.height / CGFloat(scan.rows)
        guard cell > 0 else { return nil }
        let y = { (mark: PromptMark) in Self.terminalTopInset + CGFloat(mark.row - scan.top) * cell }
        let under = { (mark: PromptMark) in y(mark) + cell / 2 < Self.stickyHeight }
        guard let current = scan.marks.lastIndex(where: under) else { return nil }
        var offset: CGFloat = 0
        if current + 1 < scan.marks.count {
            offset = min(0, y(scan.marks[current + 1]) - Self.stickyHeight)
        }
        let mark = scan.marks[current]
        let date = promptEntries.first { $0.mark == mark }?.date
        return StickyPrompt(mark: mark, index: current + 1, total: scan.marks.count, offset: offset, date: date)
    }

    /// Прокрутить так, чтобы строка запроса встала первой, а ответ начался под полосой.
    func scrollToPrompt(_ mark: PromptMark) {
        guard let scan = promptScan else { return }
        view.scrollTo(row: mark.row - scan.linesTop)
        Task { await refreshPrompts() }
    }

    /// ⌘↑ и ⌘↓. Вверх сначала к началу текущего ответа, потом к предыдущему запросу. Вниз за последним запросом
    /// к концу вывода.
    func jumpPrompt(forward: Bool) {
        guard let scan = promptScan, !scan.marks.isEmpty else { return }
        let marks = scan.marks
        let current = sticky.map { $0.index - 1 }
        let target: Int?
        if forward {
            target = current.map { $0 + 1 } ?? marks.firstIndex { $0.row > scan.top }
        } else if let current {
            target = marks[current].row == scan.top ? current - 1 : current
        } else {
            target = marks.lastIndex { $0.row < scan.top }
        }
        if let target, marks.indices.contains(target) {
            scrollToPrompt(marks[target])
        } else if forward {
            view.scroll(toPosition: 1)
            Task { await refreshPrompts() }
        }
    }
}

/// Закрепленный запрос над терминалом вкладки агента. Пока виден, раз в 150 мс перечитывает запросы.
struct StickyPromptBar: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    @State private var listing = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.allowsHitTesting(false)
            if let sticky = tab.sticky {
                bar(sticky)
                    .offset(y: sticky.offset)
            }
            PromptTicks(tab: tab, l: l)
        }
        .clipped()
        .task(id: tab.id) {
            while !Task.isCancelled {
                await tab.refreshPrompts()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func bar(_ sticky: StickyPrompt) -> some View {
        HStack(spacing: 10) {
            Button { tab.scrollToPrompt(sticky.mark) } label: {
                HStack(spacing: 8) {
                    Text(tab.spec.codexSession ? "›" : "❯").foregroundStyle(Ink.faint)
                    Text(sticky.mark.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Ink.text)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, design: .monospaced))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l.t("К началу ответа на этот запрос", "Back to the start of this answer") + "\n" + sticky.mark.text)
            if let date = sticky.date {
                Text(date, format: .dateTime.hour().minute())
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Ink.faint)
            }
            Button { listing = true } label: {
                HStack(spacing: 4) {
                    Text("\(sticky.index) / \(sticky.total)").monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 11))
                .foregroundStyle(Ink.text2)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Ink.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.hoverCapsule())
            .help(l.t("Все запросы этой вкладки", "All prompts of this tab"))
            .popover(isPresented: $listing, arrowEdge: .bottom) {
                PromptList(tab: tab, l: l) { listing = false }
            }
            arrow("chevron.up", l.t("Предыдущий запрос", "Previous prompt"), .previousPrompt) { tab.jumpPrompt(forward: false) }
            arrow("chevron.down", l.t("Следующий запрос", "Next prompt"), .nextPrompt) { tab.jumpPrompt(forward: true) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: TerminalTab.stickyHeight)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(Ink.terminalBg.opacity(0.55)))
                .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        }
    }

    private func arrow(_ icon: String, _ title: String, _ action: ShortcutAction, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Ink.text2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Ink.chip))
        }
        .buttonStyle(.hoverCircle())
        .shortcutHelp(title, action)
        .accessibilityLabel(title)
    }
}

/// Метки запросов на правом краю терминала, как на полосе прокрутки: место каждого запроса во всем выводе.
/// Текущая ярче. Наведение показывает текст запроса, клик переходит к нему.
struct PromptTicks: View {
    @ObservedObject var tab: TerminalTab
    let l: L
    @State private var hovered: PromptMark?

    var body: some View {
        GeometryReader { geo in
            if let scan = tab.promptScan, scan.bottom - scan.linesTop > scan.rows, !scan.marks.isEmpty {
                let top = TerminalTab.terminalTopInset
                let height = max(1, geo.size.height - top - 6)
                let total = CGFloat(scan.bottom - scan.linesTop)
                let entries = tab.promptEntries
                ZStack(alignment: .topTrailing) {
                    ForEach(scan.marks, id: \.row) { mark in
                        let y = top + height * CGFloat(mark.row - scan.linesTop) / total
                        let current = tab.sticky?.mark == mark
                        Button { tab.scrollToPrompt(mark) } label: {
                            Capsule()
                                .fill(current || hovered == mark ? Ink.modeOn : Ink.link.opacity(0.75))
                                .frame(width: current || hovered == mark ? 8 : 6, height: current ? 3 : 2)
                                .frame(width: 10, height: 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in hovered = inside ? mark : (hovered == mark ? nil : hovered) }
                        .position(x: geo.size.width - 5, y: y)
                        .accessibilityLabel(l.t("Перейти к запросу", "Go to the prompt") + " " + mark.text)
                    }
                    if let hovered {
                        let y = top + height * CGFloat(hovered.row - scan.linesTop) / total
                        let date = entries.first { $0.mark == hovered }?.date
                        VStack(alignment: .leading, spacing: 2) {
                            if let date {
                                Text(date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(Ink.faint)
                            }
                            Text(hovered.text).font(.system(size: 12)).foregroundStyle(Ink.text).lineLimit(3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: 360, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.hairline))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: max(190, geo.size.width - 200), y: min(max(30, y), geo.size.height - 30))
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

/// Список запросов вкладки с поиском: время и текст. Запросы, ушедшие из прокрутки терминала, бледнее, к ним
/// не перейти. Текущий выделен.
struct PromptList: View {
    @ObservedObject var tab: TerminalTab
    let l: L
    let close: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let words = query.lowercased().split(separator: " ")
        let shown = tab.promptEntries.filter { entry in words.allSatisfy { entry.text.lowercased().contains($0) } }
        VStack(alignment: .leading, spacing: 6) {
            Text(l.t("Запросы в этой вкладке", "Prompts in this tab"))
                .font(.system(size: 11))
                .foregroundStyle(Ink.faint)
                .padding(.horizontal, 6)
            TextField(l.t("Найти запрос", "Find a prompt"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                }
                .frame(height: min(CGFloat(max(shown.count, 1)) * 30, 360))
                .onAppear {
                    if let current = tab.promptEntries.first(where: { $0.mark != nil && $0.mark == tab.sticky?.mark }) {
                        proxy.scrollTo(current.id, anchor: .center)
                    } else if let last = shown.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if shown.isEmpty {
                Text(l.t("Ничего не нашлось", "Nothing found")).font(.system(size: 12)).foregroundStyle(Ink.faint).padding(6)
            }
        }
        .padding(10)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private func row(_ entry: PromptEntry) -> some View {
        let current = entry.mark != nil && entry.mark == tab.sticky?.mark
        return Button {
            if let mark = entry.mark {
                tab.scrollToPrompt(mark)
                close()
            }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let date = entry.date {
                        Text(date, format: .dateTime.hour().minute())
                    } else {
                        Text("")
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Ink.faint)
                .frame(width: 38, alignment: .leading)
                Text(entry.text.components(separatedBy: "\n").first ?? "")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(entry.mark == nil ? Ink.faint : current ? Ink.strong : Ink.text2)
                Spacer(minLength: 0)
                if entry.mark == nil {
                    Text(l.t("вне прокрутки", "out of scrollback")).font(.system(size: 10)).foregroundStyle(Ink.faint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(current ? Ink.modeOnBg : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover(7, .overlay))
        .disabled(entry.mark == nil)
        .help(entry.mark == nil ? l.t("Этот запрос уже ушел из прокрутки терминала", "This prompt has left the terminal scrollback")
                                : entry.text)
    }
}
