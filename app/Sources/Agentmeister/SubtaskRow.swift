import SwiftUI

/// Ряд подзадач под полосой вкладок: параллельные задачи выбранного агента в своих worktree, его фоновые агенты
/// и фоновые команды. В прокручиваемой ленте только то, что идет, и параллельные задачи. Закончившиеся агенты
/// и команды свернуты в два цветных счетчика у кнопки "+ задача": готовые и остановленные или упавшие. Клик по
/// счетчику открывает их список, где строка открывает вывод, а крестик убирает ее из ряда. Подпись и
/// "+ задача" стоят на месте, края ленты уходят в прозрачность, когда за ними что-то есть.
struct SubtaskRow: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @ObservedObject var root: TerminalTab
    let subtasks: [TerminalTab]

    @State private var position = ScrollPosition(edge: .leading)
    @State private var scroll = Scroll()
    @State private var list: Closed.Kind? = Demo.scene == "subtasks-list" && Demo.active ? .bad : nil
    @State private var shellSheet: BackgroundShell?
    @State private var agentSheet: SubAgent?

    private struct Scroll: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var width: CGFloat = 0
        var left: Bool { offset > 1 }
        var right: Bool { offset + width < content - 1 }
    }

    var l: L { L(backend.state.lang) }

    private var runningAgents: [SubAgent] { root.agents.filter { !$0.finished } }
    private var runningShells: [BackgroundShell] { root.shells.filter { $0.status == nil } }

    private var closed: [Closed] {
        let agents = root.agents.filter(\.finished).map { Closed(agent: $0, l: l) }
        let shells = root.shells.filter { $0.status != nil }.map { Closed(shell: $0, l: l) }
        return (agents + shells).sorted { $0.at > $1.at }
    }

    var body: some View {
        let closed = closed
        let ok = closed.filter { $0.kind == .ok }
        let bad = closed.filter { $0.kind == .bad }
        let running = subtasks.filter(\.running).count + runningAgents.count + runningShells.count
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .medium))
                Text(l.t("подзадачи агента", "agent's subtasks"))
                if running > 0 {
                    count(running, fg: Ink.amber, bg: Ink.amberDot.opacity(0.16))
                        .help(l.t("Идут", "Running"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Ink.faint)
            .padding(.leading, 18)
            .padding(.trailing, 2)
            if scroll.left || scroll.right { arrow(left: true) }
            lane
            if scroll.left || scroll.right { arrow(left: false) }
            if !ok.isEmpty { counter(.ok, ok) }
            if !bad.isEmpty { counter(.bad, bad) }
            Rectangle().fill(Ink.hairline).frame(width: 1, height: 16).padding(.horizontal, 2)
            Button {
                workspace.selected = root.id
                ui.newSessionProject = backend.state.project(containing: root.spec.projectPath)?.path ?? root.spec.projectPath
                ui.showParallel = true
            } label: {
                Label(l.t("задача", "task"), systemImage: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
            }
            .buttonStyle(.hoverCapsule())
            .help(l.t("Новая параллельная задача этого агента", "A new parallel task for this agent"))
            .padding(.trailing, 10)
        }
        .sheet(item: $shellSheet) { shell in ShellSheet(shell: shell, l: l) { remove(shell: shell.id) } }
        .sheet(item: $agentSheet) { agent in SubAgentSheet(agent: agent, l: l) }
    }

    private var lane: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(subtasks) { tab in
                    SubtaskChip(tab: tab, selected: tab.id == workspace.selected)
                }
                ForEach(runningAgents) { agent in
                    SubAgentChip(agent: agent, l: l) { remove(agent: agent.id) }
                }
                ForEach(runningShells) { shell in
                    ShellChip(shell: shell, l: l) { remove(shell: shell.id) }
                }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Scroll.self) { geo in
            Scroll(offset: geo.contentOffset.x, content: geo.contentSize.width, width: geo.containerSize.width)
        } action: { _, now in
            scroll = now
        }
        // край затухает, только когда за ним есть чипы: срезанный пополам чип не похож на кнопку
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: scroll.left ? 32 : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: scroll.right ? 32 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: scroll.left)
        .animation(.easeOut(duration: 0.15), value: scroll.right)
    }

    private func arrow(left: Bool) -> some View {
        Button {
            let step = max(120, scroll.width * 0.8)
            let target = left ? max(0, scroll.offset - step) : min(scroll.content - scroll.width, scroll.offset + step)
            withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(x: target) }
        } label: {
            Image(systemName: left ? "chevron.left" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Ink.muted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Ink.chip))
        }
        .buttonStyle(.hoverCircle())
        .disabled(left ? !scroll.left : !scroll.right)
        .opacity((left ? scroll.left : scroll.right) ? 1 : 0.35)
        .accessibilityLabel(left ? l.t("Прокрутить влево", "Scroll left") : l.t("Прокрутить вправо", "Scroll right"))
    }

    private func count(_ n: Int, fg: Color, bg: Color) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 20)
            .background(Capsule().fill(bg))
    }

    private func counter(_ kind: Closed.Kind, _ items: [Closed]) -> some View {
        let shown = Binding(get: { list == kind }, set: { if !$0 && list == kind { list = nil } })
        return Button { list = list == kind ? nil : kind } label: {
            count(items.count, fg: kind == .ok ? Ink.teal : Ink.red, bg: kind == .ok ? Ink.tealChip : Ink.redChip)
        }
        .buttonStyle(.plain)
        .help(kind == .ok ? l.t("Закончились, клик показывает список", "Finished, click for the list")
                          : l.t("Остановлены или упали, клик показывает список", "Stopped or failed, click for the list"))
        .popover(isPresented: shown, arrowEdge: .bottom) {
            ClosedList(kind: kind, items: items, l: l) { item in
                list = nil
                if let shell = item.shell { shellSheet = shell } else { agentSheet = item.agent }
            } remove: { item in
                if item.shell != nil { remove(shell: item.id) } else { remove(agent: item.id) }
            } removeAll: {
                list = nil
                for item in items {
                    if item.shell != nil { remove(shell: item.id) } else { remove(agent: item.id) }
                }
            }
        }
    }

    private func remove(shell id: String) {
        BackgroundShells.hide(id)
        root.shells.removeAll { $0.id == id }
    }

    private func remove(agent id: String) {
        SubAgents.hide(id)
        root.agents.removeAll { $0.id == id }
    }
}

/// Закончившийся фоновый агент или команда для списка за счетчиком.
struct Closed: Identifiable {
    enum Kind { case ok, bad }
    let id: String
    let title: String
    let kind: Kind
    let outcome: String
    let at: Date
    var shell: BackgroundShell?
    var agent: SubAgent?

    init(agent: SubAgent, l: L) {
        id = agent.id
        title = agent.description
        kind = .ok
        outcome = l.ago(agent.modified.timeIntervalSince1970)
        at = agent.modified
        self.agent = agent
    }

    init(shell: BackgroundShell, l: L) {
        id = shell.id
        title = shell.description
        at = shell.finishedAt ?? shell.started
        self.shell = shell
        if shell.status == "killed" || BackgroundShells.stoppedFromApp(shell.id) {
            kind = .bad
            outcome = l.t("остановлена", "stopped")
        } else if shell.failed {
            kind = .bad
            outcome = l.t("код \(shell.exitCode.map(String.init) ?? "?")", "exit \(shell.exitCode.map(String.init) ?? "?")")
        } else {
            kind = .ok
            outcome = l.ago(at.timeIntervalSince1970)
        }
    }
}

/// Список закончившихся за счетчиком: строка открывает вывод, крестик убирает ее из ряда.
private struct ClosedList: View {
    let kind: Closed.Kind
    let items: [Closed]
    let l: L
    let open: (Closed) -> Void
    let remove: (Closed) -> Void
    let removeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(kind == .ok ? l.t("Закончились", "Finished") : l.t("Остановлены или упали", "Stopped or failed"))
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.faint)
                Spacer()
                Button(l.t("Убрать все", "Remove all"), action: removeAll)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            ForEach(items) { item in
                ClosedRow(item: item, l: l) { open(item) } remove: { remove(item) }
            }
        }
        .padding(8)
        .frame(width: 400)
    }
}

private struct ClosedRow: View {
    let item: Closed
    let l: L
    let open: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Circle().fill(item.kind == .ok ? Ink.teal : Ink.red).frame(width: 7, height: 7)
                    Image(systemName: item.shell != nil ? "terminal" : "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.faint)
                    Text(item.title).lineLimit(1).truncationMode(.tail).foregroundStyle(Ink.text2)
                    Spacer(minLength: 8)
                    Text(item.outcome).font(.system(size: 11)).foregroundStyle(item.kind == .ok ? Ink.faint : Ink.red)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.shell != nil ? l.t("Показать вывод команды", "Show the command's output")
                                    : l.t("Показать переписку агента", "Show the agent's transcript"))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.hoverCircle(.overlay))
            .help(l.t("Убрать из ряда", "Remove from the row"))
            .accessibilityLabel(l.t("Убрать из ряда", "Remove from the row"))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Ink.hover : .clear))
        .onHover { hover = $0 }
    }
}
