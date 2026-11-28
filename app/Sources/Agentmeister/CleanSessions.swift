import SwiftUI

/// Что нашел agentmeister sessions clean --json. Ничего не меняется, пока человек не выбрал группы.
struct CleanReport: Decodable {
    struct Folder: Decodable, Hashable {
        let home: String
        let sessions: Int
        let size: Int
        let memory: Bool
        let open: Bool
        /// Только у папок с неверным именем: правильная папка уже есть, содержимое сольется с ней.
        let merge: Bool?
    }

    struct Link: Decodable, Hashable {
        let path: String
        let target: String
    }

    struct Empty: Decodable, Hashable {
        let id: String
        let title: String
        let size: Int
    }

    let misnamed: [Folder]
    let broken: [Link]
    let empty: [Empty]
    let orphans: [Folder]
    let away: [String]
    let unknown: Int

    var isEmpty: Bool { misnamed.isEmpty && broken.isEmpty && empty.isEmpty && orphans.isEmpty }
}

/// "Очистить лишние" в библиотеке вместо вопросов sessions clean в терминале: группы с галочками, список по
/// клику, потом sessions clean -y --only <группы> в листе команды.
struct CleanSessionsSheet: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    @Environment(\.commandHost) private var host
    var onFinish: (() async -> Void)? = nil
    @State private var report: CleanReport?
    @State private var failed = false
    /// Папки удаленных проектов не отмечены: там удаляются сессии, которые могут еще понадобиться.
    @State private var chosen: Set<String> = ["empty", "broken", "misnamed"]
    @State private var shown: Set<String> = []

    var l: L { L(backend.state.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l.t("Очистить лишние", "Clean up")).font(.system(size: 20, weight: .semibold))
                if let report {
                    Text(report.isEmpty ? l.t("Чистить нечего.", "Nothing to clean.")
                                        : l.t("Открытые сессии не трогаются.", "Open sessions are left alone."))
                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
            }
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) { groups(report) }
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                if !report.away.isEmpty || report.unknown > 0 {
                    Text(skipped(report)).font(.system(size: 11)).foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if failed {
                Text(l.t("Не получилось просмотреть сессии.", "Couldn't look through the sessions."))
                    .font(.system(size: 12)).foregroundStyle(Ink.red)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
            HStack {
                Spacer()
                Button(report?.isEmpty == true ? l.t("Готово", "Done") : l.cancel) { dismiss() }
                    .buttonStyle(PillStyle())
                    .keyboardShortcut(.cancelAction)
                if report?.isEmpty == false {
                    Button(l.t("Очистить выбранное", "Clean up selected"), action: clean)
                        .buttonStyle(PillStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
        .task {
            let result: CleanReport? = await Backend.json(["sessions", "clean", "--json"])
            report = result
            failed = result == nil
        }
    }

    /// Отмеченные группы, в которых что-то нашлось, в порядке sessions clean.
    private var selected: [String] {
        guard let report else { return [] }
        let found = ["misnamed": !report.misnamed.isEmpty, "broken": !report.broken.isEmpty,
                     "empty": !report.empty.isEmpty, "orphans": !report.orphans.isEmpty]
        return ["misnamed", "broken", "empty", "orphans"].filter { chosen.contains($0) && found[$0] == true }
    }

    @ViewBuilder private func groups(_ r: CleanReport) -> some View {
        if !r.empty.isEmpty {
            group("empty", l.t("Сессии без единого ответа", "Sessions without a single reply"),
                  "\(r.empty.count), " + Self.size(r.empty.map(\.size).reduce(0, +)), note: nil,
                  lines: r.empty.map { String($0.id.prefix(8)) + "  " + $0.title })
        }
        if !r.broken.isEmpty {
            group("broken", l.t("Битые ссылки", "Broken links"), "\(r.broken.count)", note: nil,
                  lines: r.broken.map { $0.path + " → " + $0.target })
        }
        if !r.orphans.isEmpty {
            group("orphans", l.t("Папки удаленных проектов", "Folders of deleted projects"),
                  "\(r.orphans.count), " + Self.size(r.orphans.map(\.size).reduce(0, +)),
                  note: l.t("Удаляются их сессии. Папки memory остаются на месте.", "Their sessions are deleted. memory folders stay in place."),
                  lines: r.orphans.map(folderLine))
        }
        if !r.misnamed.isEmpty {
            group("misnamed", l.t("Папки с неверным именем", "Misnamed folders"),
                  l.t("\(r.misnamed.count), перенести", "\(r.misnamed.count), move"),
                  note: l.t("Их назвал старый sessions mv, Claude Code их не видит. Они не удаляются, а переносятся в папки с правильным именем.",
                            "The old sessions mv named them, Claude Code can't see them. They aren't deleted but moved to correctly named folders."),
                  lines: r.misnamed.map(folderLine))
        }
    }

    private func folderLine(_ f: CleanReport.Folder) -> String {
        var parts = [f.home, l.t("сессий \(f.sessions)", "\(f.sessions) sessions"), Self.size(f.size)]
        if f.memory { parts.append("memory") }
        if f.merge == true { parts.append(l.t("сольется с уже существующей", "merges into the existing one")) }
        if f.open { parts.append(l.t("есть открытые, пропущу", "has open ones, skipped")) }
        return parts.joined(separator: " · ")
    }

    private func group(_ id: String, _ title: String, _ count: String, note: String?, lines: [String]) -> some View {
        let open = shown.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { chosen.contains(id) }, set: { if $0 { chosen.insert(id) } else { chosen.remove(id) } })) {
                    HStack(spacing: 8) {
                        Text(title).fontWeight(.semibold)
                        Text(count).foregroundStyle(Ink.faint)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button(open ? l.t("Скрыть", "Hide") : l.t("Показать", "Show")) {
                    withAnimation(.snappy(duration: 0.2)) { if open { shown.remove(id) } else { shown.insert(id) } }
                }
                .buttonStyle(.link).font(.system(size: 12))
            }
            .font(.system(size: 13))
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
            if open {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.text2)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
    }

    private func skipped(_ r: CleanReport) -> String {
        var parts: [String] = []
        if !r.away.isEmpty { parts.append(l.t("проекты на отключенных дисках (\(r.away.count))", "projects on disconnected disks (\(r.away.count))")) }
        if r.unknown > 0 { parts.append(l.t("папки без записи о пути (\(r.unknown))", "folders with no record of their path (\(r.unknown))")) }
        return l.t("Не трогаются: ", "Left alone: ") + parts.joined(separator: l.t(" и ", " and ")) + "."
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func clean() {
        let args = ["sessions", "clean", "-y", "--only", selected.joined(separator: ",")]
        let title = l.t("Очистить лишние", "Clean up")
        let host = self.host
        let backend = self.backend
        let after = onFinish
        dismiss()
        // лист команды открывается, когда этот уже закрылся
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            CommandRuns.shared.start(args, title: title, icon: "trash", host: host, sheet: true) {
                backend.refresh()
                await after?()
            }
        }
    }
}
