import AppKit
import SwiftUI

/// Окно "О программе" вместо стандартной панели macOS: слева значок и обновления, справа версия, сборка и ссылки
/// на автора, исходники, изменения этой версии и issues.
struct AboutView: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject private var updates = Updates.shared
    @State private var cli: String?

    var l: L { L(backend.state.lang) }

    private static let repo = "https://github.com/kopylovis/agentmeister"
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    private var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    /// Значок приложения. Отладочная сборка без .app значка не имеет (macOS дает папку), тогда берется
    /// share/agentmeister/icon.png из репозитория, из него bundle.sh собирает AppIcon.icns.
    static let icon: NSImage = {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApp.applicationIconImage }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<7 {
            guard let d = dir else { break }
            let png = d.appendingPathComponent("share/agentmeister/icon.png")
            if let image = NSImage(contentsOf: png) { return image }
            dir = d.deletingLastPathComponent()
        }
        return NSApp.applicationIconImage
    }()

    private var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion)" + (v.minorVersion > 0 ? ".\(v.minorVersion)" : "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 12) {
                Image(nsImage: Self.icon)
                    .resizable()
                    .frame(width: 112, height: 112)
                    // исходный png квадратный, у значка из .app маска уже есть
                    .clipShape(RoundedRectangle(cornerRadius: Bundle.main.bundleURL.pathExtension == "app" ? 0 : 25,
                                                style: .continuous))
                    .accessibilityHidden(true)
                updatesBlock
            }
            .frame(width: 150)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agentmeister").font(.system(size: 24, weight: .bold))
                    Text(([version] + (build.map { [l.t("сборка ", "build ") + $0] } ?? []) + [macOS]).joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(Ink.muted)
                        .textSelection(.enabled)
                }
                Text(l.t("Проекты, сессии, режимы и proxy для каждой сессии Claude Code и Codex.",
                         "Projects, sessions, modes and a per-session proxy for Claude Code and Codex."))
                    .font(.system(size: 13)).foregroundStyle(Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    link(l.t("Автор", "Author"), "github.com/kopylovis", "https://github.com/kopylovis")
                    link(l.t("Исходники", "Source"), "kopylovis/agentmeister", Self.repo)
                    // у сборки из исходников нет своей страницы релиза
                    if version != "dev" {
                        link(l.t("Изменения", "Changes"), l.t("Что нового в \(version)", "What's new in \(version)"),
                             Self.repo + "/releases/tag/v\(version)")
                    }
                    link(l.t("Проблемы", "Problems"), l.t("Открыть issue", "Open an issue"), Self.repo + "/issues/new")
                    GridRow {
                        Text("CLI").foregroundStyle(Ink.muted)
                        Text(cli ?? tilde(LoginEnvironment.agentmeister))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Ink.text)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 26)
        .frame(width: 600)
        .background(WindowDragArea())
        .task {
            // версия CLI и путь к нему: в DMG свой agentmeister, а у разработчика он может смотреть в репозиторий
            guard LoginEnvironment.found else { return }
            let r = await Task.detached(priority: .utility) { Backend.runForText(["--version"]) }.value
            let path = tilde(LoginEnvironment.agentmeister)
            cli = r.ok && !r.text.isEmpty ? "agentmeister \(r.text), \(path)" : path
        }
    }

    @ViewBuilder
    private var updatesBlock: some View {
        if updates.available {
            if let ready = updates.ready {
                Text(l.t("Скачана версия \(ready)", "Version \(ready) is downloaded"))
                    .font(.system(size: 12)).foregroundStyle(Ink.teal).multilineTextAlignment(.center)
                Button(l.t("Перезапустить и обновить", "Restart to update")) { updates.installNow() }
                    .buttonStyle(PillStyle(small: true))
            } else {
                Text(lastCheckText)
                    .font(.system(size: 12)).foregroundStyle(Ink.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l.t("Проверить обновления…", "Check for Updates…")) { updates.check() }
                    .buttonStyle(PillStyle(small: true))
            }
        } else {
            Text(l.t("Сборка из исходников, обновления через git", "Built from source, updates come through git"))
                .font(.system(size: 12)).foregroundStyle(Ink.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return l.t("Обновления еще не проверялись", "Updates not checked yet") }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: l.en ? "en_US" : "ru_RU")
        f.unitsStyle = .short
        return l.t("Проверено ", "Checked ") + f.localizedString(for: date, relativeTo: Date())
    }

    private func link(_ label: String, _ title: String, _ url: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Ink.muted)
            Link(title, destination: URL(string: url)!)
                .help(url)
        }
    }
}

/// Пункт "О программе" в меню приложения: открывает AboutView вместо стандартной панели.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow
    let l: L

    var body: some View {
        Button(l.t("О программе Agentmeister", "About Agentmeister")) {
            NSApp.activate()
            openWindow(id: "about")
        }
    }
}
