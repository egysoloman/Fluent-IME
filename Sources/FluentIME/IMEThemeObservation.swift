import AppKit
import FluentKit

/// Keeps requested System separate from the concrete palette already painted by a surface.
final class IMEThemeObservation {
    static var current: FluentTheme {
        FluentThemeResolver.resolve(theme: Preferences.shared.theme,
            using: NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua) ?? NSAppearance())
    }

    private var lastTheme = IMEThemeObservation.current
    private var lastFonts = FontPreferences.signature
    private var lastEffects = Preferences.shared.advancedEffects
    private var lastIndicator = Preferences.shared.showInputModeIndicator
    private let update: (FluentTheme) -> Void
    private var appearance: NSKeyValueObservation?
    private var preferences: NSObjectProtocol?

    init(_ update: @escaping (FluentTheme) -> Void) {
        self.update = update
        appearance = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in self?.refresh() }
        preferences = NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }; return
        }
        let next = Self.current
        let effects = Preferences.shared.advancedEffects, indicator = Preferences.shared.showInputModeIndicator
        guard lastFonts != FontPreferences.signature || next != lastTheme || effects != lastEffects || indicator != lastIndicator else { return }
        lastFonts = FontPreferences.signature
        lastTheme = next; lastEffects = effects; lastIndicator = indicator
        update(next)
    }

    deinit { if let preferences { NotificationCenter.default.removeObserver(preferences) } }
}
