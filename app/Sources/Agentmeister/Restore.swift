import SwiftUI

/// Лист восстановления по макету Restore.dc.html: после сбоя приложения или перезагрузки Mac спрашивает,
/// какие сессии открыть снова. После обычного выхода вкладки открываются без него.
struct RestoreSheet: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    let pending: Workspace.PendingRestore
    @State private var chosen: Set<Int> = []
    @AppStorage(Workspace.reopenSilentlyKey) private var silently = false

    var l: L { L(backend.state.lang) }

    private func count(_ n: Int) -> String { l.count(n, "сессия", "сессии", "сессий", "session", "sessions") }

    var body: some View {
        let n = pending.specs.count
        VStack(alignment: .leading, spacing: 16) {
            Text(pending.reason == .crash ? l.t("Agentmeister закрылся неожиданно", "Agentmeister quit unexpectedly")
                                          : l.t("После перезагрузки", "After the restart"))
                .font(.system(size: 17, weight: .semibold))
            Text(pending.reason == .crash
                 ? l.t("Были открыты \(count(n)). Агенты в них остановились вместе с приложением.",
                       "\(count(n)) \(n == 1 ? "was" : "were") open. Their agents stopped together with the app.")
                 : l.t("До перезагрузки Mac были открыты \(count(n)). Открыть их снова?",
                       "\(count(n)) \(n == 1 ? "was" : "were") open before the Mac restarted. Open \(n == 1 ? "it" : "them") again?"))
                .foregroundStyle(Ink.muted)
            VStack(spacing: 4) {
                ForEach(Array(pending.specs.enumerated()), id: \.offset) { index, item in
                    row(index, item.spec)
                }
            }
            Note(text: l.t("Сессии продолжатся с того же места. Маршрут, режим \"не спать\" и флаги запуска возьмутся те же, что были.",
                           "Sessions resume where they left off, with the same route, stay-awake mode and launch flags."))
            HStack(spacing: 8) {
                Toggle(l.t("Открывать без вопроса", "Reopen without asking"), isOn: $silently)
                Spacer()
                PillButton(title: l.t("Не открывать", "Don't open")) { workspace.finishRestore([]) }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: l.t("Открыть \(chosen.count)", "Open \(chosen.count)"), prominent: true) {
                    workspace.finishRestore(pending.specs.enumerated().filter { chosen.contains($0.offset) }.map(\.element))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { chosen = Set(pending.specs.indices) }
    }

    private func row(_ index: Int, _ spec: LaunchSpec) -> some View {
        let on = chosen.contains(index)
        let title = spec.resumeId.flatMap { id in backend.state.sessions.first { $0.id == id }?.title }.flatMap { $0.isEmpty ? nil : $0 }
            ?? spec.projectName
        return Button {
            if on { chosen.remove(index) } else { chosen.insert(index) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : Ink.muted)
                AgentBadge(agent: spec.agent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).foregroundStyle(on ? Ink.strong : Ink.muted)
                    Text(tilde(spec.projectPath)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint).lineLimit(1)
                }
                Spacer()
                Text(spec.routeLabel(l))
                    .font(.system(size: 11))
                    .foregroundStyle(spec.direct ? Ink.direct : Ink.teal)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(spec.direct ? Ink.amberDot.opacity(0.14) : Ink.tealChip))
                if spec.awake {
                    Text(l.t("не спать", "stay awake"))
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.modeOn)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Ink.modeOnBg))
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Ink.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover(12))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
