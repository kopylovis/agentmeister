import SwiftTerm
import SwiftUI

/// Запрос пользователя в выводе вкладки Claude Code: строка "❯ текст" на подложке. В классическом режиме Claude Code
/// печатает каждый запрос так в прокрутку. Строка ввода внизу тоже начинается с "❯", но без подложки.
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
}

/// Результат прохода по буферу.
struct PromptScan {
    let marks: [PromptMark]
    /// Сквозной номер верхней видимой строки.
    let top: Int
    /// Сквозной номер первой строки, которую терминал еще хранит. scrollTo(row:) считает от нее.
    let linesTop: Int
    let rows: Int
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

    func update(_ ref: TerminalRef) -> PromptScan? {
        lock.lock()
        defer { lock.unlock() }
        let view = ref.view
        guard let viewport = view.terminalContentSnapshot(region: .viewport), viewport.bufferKind == .normal,
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
        if scanned < linesTop {
            scanned = linesTop
            history.removeAll { $0.row < linesTop }
        }
        while scanned < liveTop {
            let end = min(scanned + 600, liveTop)
            guard let chunk = view.terminalContentSnapshot(region: .rows(scanned..<end)) else { break }
            history += chunk.rows.compactMap(Self.mark)
            scanned = end
        }
        let live = view.terminalContentSnapshot(region: .rows(liveTop..<(liveTop + rows)))?.rows.compactMap(Self.mark) ?? []
        return PromptScan(marks: history + live, top: viewport.capturedRange.lowerBound, linesTop: linesTop, rows: rows)
    }

    /// Строка запроса: первый непустой символ "❯" на цветной подложке.
    private static func mark(_ row: TerminalContentRowSnapshot) -> PromptMark? {
        guard !row.isWrapped, let first = row.cells.firstIndex(where: { !$0.isBlank }) else { return nil }
        let cell = row.cells[first]
        guard cell.text == "❯", cell.attribute.bg != .defaultColor, cell.attribute.bg != .defaultInvertedColor else { return nil }
        var text = row.text.trimmingCharacters(in: .whitespaces)
        text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        return PromptMark(row: row.absoluteRow, text: text)
    }
}

extension TerminalTab {
    /// Высота закрепленной полосы и отступ терминала от верха контейнера (TerminalHost).
    static let stickyHeight: CGFloat = 34
    static let terminalTopInset: CGFloat = 14

    /// Перечитать запросы и пересчитать закрепленную полосу. Только у Claude Code: метка запроса его.
    func refreshPrompts() async {
        guard spec.agent == .claude, spec.utility == nil else {
            if sticky != nil { sticky = nil }
            return
        }
        let ref = TerminalRef(view: view)
        let index = promptIndex
        promptScan = await Task.detached(priority: .userInitiated) { index.update(ref) }.value
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
        return StickyPrompt(mark: scan.marks[current], index: current + 1, total: scan.marks.count, offset: offset)
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

/// Закрепленный запрос над терминалом вкладки Claude Code. Пока виден, раз в 150 мс перечитывает запросы.
struct StickyPromptBar: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab

    var l: L { L(backend.state.lang) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let sticky = tab.sticky {
                bar(sticky)
                    .offset(y: sticky.offset)
            }
        }
        .clipped()
        .allowsHitTesting(tab.sticky != nil)
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
                    Text("❯").foregroundStyle(Ink.faint)
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
            Text("\(sticky.index) / \(sticky.total)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Ink.muted)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(Ink.chip))
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
