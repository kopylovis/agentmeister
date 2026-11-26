import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Сочетание клавиш: клавиша, модификаторы и код клавиши. Меню берет клавишу и модификаторы, глобальная клавиша
/// через Carbon берет код. Два сочетания равны, если совпадают клавиша и модификаторы: код зависит от раскладки.
struct KeyCombo: Codable, Hashable {
    /// Символ в нижнем регистре ("n", "1", ",") или имя особой клавиши: tab, space, return, escape, delete,
    /// forwardDelete, left, right, up, down, home, end, pageUp, pageDown.
    var key: String
    /// NSEvent.ModifierFlags, только command, option, control и shift.
    var modifiers: UInt
    var keyCode: UInt16

    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(_ key: String, _ flags: NSEvent.ModifierFlags, code: Int) {
        self.key = key
        modifiers = flags.intersection(Self.mask).rawValue
        keyCode = UInt16(code)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.mask) }

    static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.key == b.key && a.flags == b.flags }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(flags.rawValue)
    }

    /// Как в меню macOS: ⌃⌥⇧⌘, затем клавиша.
    var label: String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + keyLabel
    }

    private var keyLabel: String {
        switch key {
        case "tab": return "⇥"
        case "space": return "Space"
        case "return": return "↩"
        case "escape": return "⎋"
        case "delete": return "⌫"
        case "forwardDelete": return "⌦"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "home": return "↖"
        case "end": return "↘"
        case "pageUp": return "⇞"
        case "pageDown": return "⇟"
        default: return key.uppercased()
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "tab": return .tab
        case "space": return .space
        case "return": return .return
        case "escape": return .escape
        case "delete": return .delete
        case "forwardDelete": return .deleteForward
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "home": return .home
        case "end": return .end
        case "pageUp": return .pageUp
        case "pageDown": return .pageDown
        default: return KeyEquivalent(key.first ?? " ")
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var out: SwiftUI.EventModifiers = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.shift) { out.insert(.shift) }
        return out
    }

    var shortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }

    var carbonModifiers: UInt32 {
        var out = 0
        if flags.contains(.command) { out |= cmdKey }
        if flags.contains(.option) { out |= optionKey }
        if flags.contains(.control) { out |= controlKey }
        if flags.contains(.shift) { out |= shiftKey }
        return UInt32(out)
    }

    /// Клавиша с символом (буква, цифра, знак), а не Tab, стрелка или другая особая.
    var isCharacter: Bool { key.count == 1 }

    /// Почему сочетание нельзя дать действию, или nil, если можно. Пункт меню без ⌘ отнял бы у терминала
    /// управляющие клавиши (⌃C, ⌃D, ⌃R, ⌃Z, ⌥B, ⌥F); исключение ⌃Tab и ⌃⇧Tab, их терминал не использует.
    /// Глобальная клавиша действует во всех приложениях, поэтому ей нужно два модификатора или ⌘ с особой
    /// клавишей (⌘Space), а ⌃ или ⌥ с одной буквой не подходят.
    func refusal(for action: ShortcutAction, l: L) -> String? {
        if action == .showApp {
            let count = [NSEvent.ModifierFlags.command, .control, .option, .shift].filter { flags.contains($0) }.count
            let strong = !flags.intersection([.command, .control, .option]).isEmpty
            if (count >= 2 && strong) || (flags.contains(.command) && !isCharacter) { return nil }
            return l.t("Клавише для всех приложений нужно два модификатора, например ⌃⌥Space. Esc отменяет.",
                       "A shortcut for all apps needs two modifiers, like ⌃⌥Space. Esc cancels.")
        }
        if flags.contains(.command) { return nil }
        if key == "tab" && flags.contains(.control) { return nil }
        if flags.isEmpty {
            return l.t("Нужен ⌘. Esc отменяет.", "Add ⌘. Esc cancels.")
        }
        return l.t("Нужен ⌘: без него \(label) не дойдет до терминала. Esc отменяет.",
                   "Add ⌘: without it \(label) would never reach the terminal. Esc cancels.")
    }

    private static let special: [Int: String] = [
        kVK_Tab: "tab", kVK_Space: "space", kVK_Return: "return", kVK_ANSI_KeypadEnter: "return", kVK_Escape: "escape",
        kVK_Delete: "delete", kVK_ForwardDelete: "forwardDelete", kVK_LeftArrow: "left", kVK_RightArrow: "right",
        kVK_UpArrow: "up", kVK_DownArrow: "down", kVK_Home: "home", kVK_End: "end", kVK_PageUp: "pageUp", kVK_PageDown: "pageDown",
    ]

    /// Клавиши US-раскладки: так macOS сопоставляет ⌘-сочетания, когда включена русская или другая не латинская.
    private static let us: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g",
        kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n",
        kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u",
        kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6",
        kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
    ]

    /// Сочетание из нажатия. nil для клавиш, которые меню не принимает (F1–F12 и т. п.).
    static func from(_ event: NSEvent) -> KeyCombo? {
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(mask)
        if let name = special[code] { return KeyCombo(name, flags, code: code) }
        // символ без модификаторов: ⇧⌘P записываем как p с shift, а не P
        if let chars = event.characters(byApplyingModifiers: [])?.lowercased(), chars.count == 1,
           let scalar = chars.unicodeScalars.first, scalar.isASCII, scalar.value > 0x20, scalar.value < 0x7F {
            return KeyCombo(chars, flags, code: code)
        }
        return us[code].map { KeyCombo($0, flags, code: code) }
    }
}

/// Действия с горячей клавишей, которую можно поменять в Настройки → Горячие клавиши.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newSession, newTab, newTerminal, closeTab, previousPrompt, nextPrompt, nextTab, previousTab, waitingTab, restart, parallel
    case palette, library, usage, ask, shot, inspector, sidebar, showApp

    var id: String { rawValue }

    var defaultCombo: KeyCombo {
        switch self {
        case .newSession: return KeyCombo("n", .command, code: kVK_ANSI_N)
        case .newTab: return KeyCombo("t", .command, code: kVK_ANSI_T)
        case .newTerminal: return KeyCombo("t", [.command, .control], code: kVK_ANSI_T)
        case .previousPrompt: return KeyCombo("up", .command, code: kVK_UpArrow)
        case .nextPrompt: return KeyCombo("down", .command, code: kVK_DownArrow)
        case .closeTab: return KeyCombo("w", .command, code: kVK_ANSI_W)
        case .nextTab: return KeyCombo("tab", .control, code: kVK_Tab)
        case .previousTab: return KeyCombo("tab", [.control, .shift], code: kVK_Tab)
        case .waitingTab: return KeyCombo("j", .command, code: kVK_ANSI_J)
        case .restart: return KeyCombo("r", .command, code: kVK_ANSI_R)
        case .parallel: return KeyCombo("p", [.command, .shift], code: kVK_ANSI_P)
        case .palette: return KeyCombo("k", .command, code: kVK_ANSI_K)
        case .library: return KeyCombo("o", [.command, .shift], code: kVK_ANSI_O)
        case .usage: return KeyCombo("u", [.command, .shift], code: kVK_ANSI_U)
        case .ask: return KeyCombo("a", [.command, .shift], code: kVK_ANSI_A)
        case .shot: return KeyCombo("s", [.command, .shift], code: kVK_ANSI_S)
        case .inspector: return KeyCombo("i", [.command, .option], code: kVK_ANSI_I)
        case .sidebar: return KeyCombo("s", [.command, .control], code: kVK_ANSI_S)
        // ⌥Space не берем: его занимает ChatGPT
        case .showApp: return KeyCombo("space", [.control, .option], code: kVK_Space)
        }
    }

    func title(_ l: L) -> String {
        switch self {
        case .newSession: return l.newSession
        case .newTab: return l.t("Новая вкладка в этом проекте", "New tab in this project")
        case .newTerminal: return l.newTerminal
        case .previousPrompt: return l.t("Предыдущий запрос", "Previous prompt")
        case .nextPrompt: return l.t("Следующий запрос", "Next prompt")
        case .closeTab: return l.closeTab
        case .nextTab: return l.t("Следующая вкладка", "Next tab")
        case .previousTab: return l.t("Предыдущая вкладка", "Previous tab")
        case .waitingTab: return l.t("К вкладке, которая ждет", "Jump to the waiting tab")
        case .restart: return l.restart
        case .parallel: return l.t("Параллельная задача", "Parallel task")
        case .palette: return l.t("Палитра команд", "Command palette")
        case .library: return l.t("Сессии", "Session library")
        case .usage: return l.t("Статистика", "Usage")
        case .ask: return l.t("Спросить другой проект", "Ask another project")
        case .shot: return l.t("Снимок окна", "Window screenshot")
        case .inspector: return l.inspector
        case .sidebar: return l.t("Свернуть или развернуть проекты", "Collapse or expand projects")
        case .showApp: return l.t("Показать Agentmeister из любого приложения", "Show Agentmeister from any app")
        }
    }
}

/// Сочетания, которые не меняются: системные (⌘Q, ⌘, и правка текста) и ⌘1…9 для вкладок. Их нельзя отдать
/// другому действию.
enum ReservedShortcuts {
    static func all(_ l: L) -> [(combo: KeyCombo, title: String)] {
        var out: [(KeyCombo, String)] = [
            (KeyCombo("q", .command, code: kVK_ANSI_Q), l.t("Закрыть Agentmeister", "Quit Agentmeister")),
            (KeyCombo(",", .command, code: kVK_ANSI_Comma), l.t("Настройки", "Settings")),
            (KeyCombo("h", .command, code: kVK_ANSI_H), l.t("Скрыть Agentmeister", "Hide Agentmeister")),
            (KeyCombo("h", [.command, .option], code: kVK_ANSI_H), l.t("Скрыть остальные", "Hide others")),
            (KeyCombo("m", .command, code: kVK_ANSI_M), l.t("Свернуть окно", "Minimize")),
            (KeyCombo("f", [.command, .control], code: kVK_ANSI_F), l.t("Полный экран", "Full screen")),
            (KeyCombo("`", .command, code: kVK_ANSI_Grave), l.t("Следующее окно", "Next window")),
            (KeyCombo("c", .command, code: kVK_ANSI_C), l.t("Скопировать", "Copy")),
            (KeyCombo("v", .command, code: kVK_ANSI_V), l.t("Вставить", "Paste")),
            (KeyCombo("x", .command, code: kVK_ANSI_X), l.t("Вырезать", "Cut")),
            (KeyCombo("a", .command, code: kVK_ANSI_A), l.t("Выбрать все", "Select all")),
            (KeyCombo("z", .command, code: kVK_ANSI_Z), l.t("Отменить", "Undo")),
            (KeyCombo("z", [.command, .shift], code: kVK_ANSI_Z), l.t("Повторить", "Redo")),
            (KeyCombo("return", .command, code: kVK_Return), l.t("Открыть в новой вкладке", "Open in a new tab")),
            (KeyCombo("f", .command, code: kVK_ANSI_F), l.t("Найти в терминале", "Find in the terminal")),
            (KeyCombo("g", .command, code: kVK_ANSI_G), l.t("Найти следующее", "Find next")),
            (KeyCombo("g", [.command, .shift], code: kVK_ANSI_G), l.t("Найти предыдущее", "Find previous")),
            (KeyCombo("e", .command, code: kVK_ANSI_E), l.t("Искать выделенное", "Use selection for find")),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, code) in digits.enumerated() {
            out.append((KeyCombo(String(index + 1), .command, code: code), l.t("Вкладка \(index + 1)", "Tab \(index + 1)")))
        }
        return out.map { (combo: $0.0, title: $0.1) }
    }
}

/// Горячие клавиши приложения. Свои сочетания хранятся в UserDefaults (shortcuts), остальные берутся по
/// умолчанию. Меню читает их отсюда, поэтому новое сочетание действует сразу, без перезапуска.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    static let defaultsKey = "shortcuts"

    /// Свое сочетание действия. combo nil значит, что сочетание убрали.
    private struct Override: Codable { var combo: KeyCombo? }

    @Published private var overrides: [String: Override] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Override].self, from: data) {
            overrides = saved.filter { ShortcutAction(rawValue: $0.key) != nil }
        }
    }

    func combo(_ action: ShortcutAction) -> KeyCombo? {
        if let custom = overrides[action.rawValue] { return custom.combo }
        return action.defaultCombo
    }

    func shortcut(_ action: ShortcutAction) -> KeyboardShortcut? { combo(action)?.shortcut }

    /// Сочетание для подсказок: "⌘N", или пусто, если его убрали.
    func label(_ action: ShortcutAction) -> String { combo(action)?.label ?? "" }

    /// Подсказка кнопки с сочетанием через запятую, как "Новая сессия, ⌘N".
    func help(_ text: String, _ action: ShortcutAction) -> String {
        let key = label(action)
        return key.isEmpty ? text : text + ", " + key
    }

    var allDefault: Bool { overrides.isEmpty }

    /// Кто уже занял сочетание: другое действие или системное сочетание. nil, если свободно.
    func conflict(_ combo: KeyCombo, for action: ShortcutAction, l: L) -> String? {
        if let other = ShortcutAction.allCases.first(where: { $0 != action && self.combo($0) == combo }) { return other.title(l) }
        return ReservedShortcuts.all(l).first { $0.combo == combo }?.title
    }

    func set(_ action: ShortcutAction, _ combo: KeyCombo?) {
        overrides[action.rawValue] = combo == action.defaultCombo ? nil : Override(combo: combo)
        save()
        if action == .showApp { HotKey.shared.apply() }
    }

    func reset() {
        overrides = [:]
        save()
        HotKey.shared.apply()
    }

    private func save() {
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension View {
    /// Горячая клавиша действия из ShortcutStore. Меняется сразу, как ее поменяли в настройках.
    func shortcut(_ action: ShortcutAction) -> some View { modifier(ShortcutModifier(action: action)) }

    /// Подсказка с текущим сочетанием действия.
    func shortcutHelp(_ text: String, _ action: ShortcutAction) -> some View { modifier(ShortcutHelpModifier(text: text, action: action)) }
}

private struct ShortcutModifier: ViewModifier {
    @ObservedObject private var store = ShortcutStore.shared
    let action: ShortcutAction

    func body(content: Content) -> some View { content.keyboardShortcut(store.shortcut(action)) }
}

private struct ShortcutHelpModifier: ViewModifier {
    @ObservedObject private var store = ShortcutStore.shared
    let text: String
    let action: ShortcutAction

    func body(content: Content) -> some View { content.help(store.help(text, action)) }
}

/// Глобальная клавиша "показать Agentmeister" (по умолчанию ⌃⌥Space) через Carbon, без Универсального доступа.
/// Если ее уже заняло другое приложение, ставит hotkey.taken, и настройки показывают это.
@MainActor
final class HotKey {
    static let shared = HotKey()
    static let enabledKey = "hotkey.showApp"
    static let takenKey = "hotkey.taken"

    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Зарегистрировать клавишу заново по текущим настройкам: включена ли она и какое сочетание.
    func apply() {
        suspend()
        UserDefaults.standard.removeObject(forKey: Self.takenKey)
        guard Self.enabled, let combo = ShortcutStore.shared.combo(.showApp) else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x414D5354), id: 1)  // "AMST"
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            ref = nil
            UserDefaults.standard.set(true, forKey: Self.takenKey)
        }
    }

    /// Снять клавишу, пока в настройках записывают новое сочетание: иначе Carbon перехватил бы нажатие.
    func suspend() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                NSApp.activate()
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Agentmeister" }?
                    .makeKeyAndOrderFront(nil)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Запись нового сочетания в настройках: локальный монитор нажатий, пока выбрана строка. Esc отменяет,
/// Delete убирает сочетание. Занятое сочетание не принимаем и пишем, кем оно занято.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: ShortcutAction?
    /// Сообщение под строкой: занято, нужен модификатор, клавиша не подходит.
    @Published private(set) var message: (action: ShortcutAction, text: String)?
    private var monitor: Any?
    private weak var window: NSWindow?
    private var l = L("en")

    func toggle(_ action: ShortcutAction, l: L) {
        if recording == action { stop() } else { start(action, l: l) }
    }

    func start(_ action: ShortcutAction, l: L) {
        stop()
        self.l = l
        recording = action
        message = nil
        window = NSApp.keyWindow
        HotKey.shared.suspend()
        // монитор зовется на главном потоке
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // nil из handle значит "нажатие съедено", поэтому не через ??
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil {
            recording = nil
            HotKey.shared.apply()
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let action = recording else { return event }
        // ушли в другое окно, не закончив запись: нажатие для него, а запись заканчиваем
        if let window, event.window !== window {
            stop()
            return event
        }
        let flags = event.modifierFlags.intersection(KeyCombo.mask)
        let code = Int(event.keyCode)
        if flags.isEmpty && code == kVK_Escape {
            message = nil
            stop()
            return nil
        }
        if flags.isEmpty && (code == kVK_Delete || code == kVK_ForwardDelete) {
            message = nil
            ShortcutStore.shared.set(action, nil)
            stop()
            return nil
        }
        guard let combo = KeyCombo.from(event) else {
            message = (action, l.t("Эту клавишу нельзя назначить. Esc отменяет.", "This key can't be a shortcut. Esc cancels."))
            return nil
        }
        if let refusal = combo.refusal(for: action, l: l) {
            message = (action, refusal)
            return nil
        }
        if combo == ShortcutStore.shared.combo(action) {
            message = nil
            stop()
            return nil
        }
        if let other = ShortcutStore.shared.conflict(combo, for: action, l: l) {
            message = (action, l.t("\(combo.label) уже занято: \(other). Нажми другое или Esc.",
                                   "\(combo.label) is already used by \(other). Press another or Esc."))
            return nil
        }
        message = nil
        ShortcutStore.shared.set(action, combo)
        stop()
        return nil
    }
}
