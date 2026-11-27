import AppKit
import Combine
import Sparkle
import SwiftUI

/// Обновления через Sparkle, как в tossling desktop. Работают только в релизной сборке: в ее Info.plist есть
/// SUFeedURL, SUPublicEDKey и AgentmeisterDistribution. Сборка для себя (make app, host-run install) не
/// обновляется, иначе релизный DMG заменил бы ее.
///
/// Sparkle сам раз в день проверяет appcast и скачивает новую версию. Ставит ее при выходе из приложения,
/// а не сразу: перезапуск остановил бы агентов во вкладках. Скачанную версию видно в меню приложения и в меню
/// строки меню, оттуда ее можно поставить сразу. Вкладки после перезапуска вернутся сами.
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?
    /// Скачанная версия, которая ждет выхода из приложения.
    @Published private(set) var ready: String?
    private var install: (() -> Void)?

    static var distributed: Bool {
        Bundle.main.object(forInfoDictionaryKey: "AgentmeisterDistribution") as? Bool == true
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    /// Sparkle запущен. Published: меню приложения строится раньше, чем start() в applicationDidFinishLaunching,
    /// и без уведомления пункт "Проверить обновления" так и не появлялся.
    @Published private(set) var available = false

    func start() {
        guard Self.distributed, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        available = true
    }

    /// Когда Sparkle последний раз проверял обновления, для окна "О программе".
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func check() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// Поставить скачанную версию сейчас: приложение закроется (с вопросом, если агенты заняты) и откроется снова.
    func installNow() {
        install?()
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            install = immediateInstallHandler
            ready = version
        }
        return true
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}

/// Пункты меню приложения: проверить обновления и, когда версия скачана, поставить ее.
struct UpdateCommands: View {
    @ObservedObject var updates = Updates.shared
    let l: L

    var body: some View {
        if updates.available {
            Button(l.t("Проверить обновления…", "Check for Updates…")) { updates.check() }
            if let version = updates.ready {
                Button(l.t("Перезапустить и обновить до \(version)", "Restart to Update to \(version)")) { updates.installNow() }
            }
        }
    }
}
