import AppKit
import Combine
import KeyboardShortcuts

enum FontFamily: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif (New York)"
        case .mono: "Monospaced"
        }
    }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension KeyboardShortcuts.Name {
    static let toggleNote = Self("toggleNote", initial: .init(.space, modifiers: [.control, .shift]))
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var gestureEnabled: Bool { didSet { defaults.set(gestureEnabled, forKey: "gestureEnabled") } }
    /// 0 = Apple's clear Liquid Glass, 0.5 = regular Liquid Glass, 1 = tinted, nearly solid.
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    @Published var fontFamily: FontFamily { didSet { defaults.set(fontFamily.rawValue, forKey: "fontFamily") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var focusGlow: Bool { didSet { defaults.set(focusGlow, forKey: "focusGlow") } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    @Published var theme: ThemeMode { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var notesFolder: URL { didSet { defaults.set(notesFolder.path, forKey: "notesFolder") } }

    static var defaultNotesFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tachibanayu24.SidecarNote", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    static let fontSizeRange: ClosedRange<Double> = 11...24
    static let defaultFontSize: Double = 14

    private init() {
        gestureEnabled = defaults.object(forKey: "gestureEnabled") as? Bool ?? true
        opacity = defaults.object(forKey: "opacity") as? Double ?? 0.5
        fontFamily = FontFamily(rawValue: defaults.string(forKey: "fontFamily") ?? "") ?? .system
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? Preferences.defaultFontSize
        focusGlow = defaults.object(forKey: "focusGlow") as? Bool ?? true
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        theme = ThemeMode(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        if let path = defaults.string(forKey: "notesFolder") {
            notesFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            notesFolder = Preferences.defaultNotesFolder
        }
    }
}
