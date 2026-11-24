import AppKit
import SwiftUI

/// Иконка проекта из его же файлов: AppIcon iOS, ic_launcher Android, icon.png, apple-touch-icon, favicon.
/// Ищется один раз в фоне, обход не глубже 7 папок и мимо сборок, зависимостей и чужого кода.
@MainActor
final class ProjectIcons: ObservableObject {
    static let shared = ProjectIcons()
    @Published private var icons: [String: NSImage] = [:]
    private var looked: Set<String> = []

    func icon(for path: String) -> NSImage? {
        if !looked.contains(path) {
            looked.insert(path)
            Task.detached(priority: .utility) {
                guard let file = Self.find(in: path), let image = NSImage(contentsOfFile: file) else { return }
                await MainActor.run { self.icons[path] = image }
            }
        }
        return icons[path]
    }

    private nonisolated static let skip: Set<String> = ["node_modules", ".git", "build", ".build", "Pods", "DerivedData", ".gradle",
                                                        ".worktrees", "dist", "third_party", "vendor", ".venv", "venv", "target", ".next"]

    /// Лучший кандидат: чем ближе к иконке приложения и чем мельче вложенность, тем выше.
    nonisolated static func find(in root: String) -> String? {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var best: (score: Double, path: String)?
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 60_000 { break }
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skip.contains(name) || walker.level > 7 { walker.skipDescendants() }
                continue
            }
            let lower = name.lowercased()
            let parent = url.deletingLastPathComponent().lastPathComponent
            var score: Double
            if parent.hasSuffix(".appiconset") && lower.hasSuffix(".png") {
                if lower.contains("dark") || lower.contains("tinted") { continue }
                let size = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                score = 100 + min(size / 100_000, 9)
            } else if parent == "mipmap-xxxhdpi" && (lower == "ic_launcher.png" || lower == "ic_launcher.webp") {
                score = 90
            } else if lower == "icon.png" {
                score = 80
            } else if lower == "logo.png" {
                score = 70
            } else if lower == "apple-touch-icon.png" {
                score = 60
            } else if lower == "favicon.png" {
                score = 50
            } else if lower == "favicon.svg" {
                score = 45
            } else {
                continue
            }
            score -= Double(walker.level)
            if best == nil || score > best!.score { best = (score, url.path) }
        }
        return best?.path
    }
}

/// Иконка проекта или папка, если иконки нет.
struct ProjectIconView: View {
    @ObservedObject private var icons = ProjectIcons.shared
    let path: String
    var size: CGFloat = 16

    var body: some View {
        if let image = icons.icon(for: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        } else {
            Image(systemName: "folder")
                .font(.system(size: size * 0.8))
                .foregroundStyle(Ink.muted)
                .frame(width: size, height: size)
        }
    }
}
