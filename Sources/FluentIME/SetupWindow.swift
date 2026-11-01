import AppKit
import FluentKit
import FluentIMECore

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let root = IMEFlippedView()
    private let content = IMEFlippedView()
    private let installation: SetupInstallation
    private let onComplete: () -> Void
    private var theme = Preferences.shared.theme
    private var appearance: IMEThemeObservation?
    private var activeObserver: NSObjectProtocol?
    private var step = 0
    private var resetDictionary = false
    private var busy = false
    private var completed = false
    private var status = ""
    private var modes = Preferences.shared.enabledInputModes
    private var defaultMode = Preferences.shared.defaultInputMode
    private var recording = Preferences.shared.clipboardRecording
    private var retention = Preferences.shared.clipboardRetention
    private var effects = Preferences.shared.advancedEffects
    private var indicator = Preferences.shared.showInputModeIndicator
    init(installation: SetupInstallation = InputMethodInstallation.shared, onComplete: @escaping () -> Void = {}) {
        self.installation = installation; self.onComplete = onComplete
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.installTitle; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; window.contentView = root; root.wantsLayer = true
        root.fluentSetLocalization(locale: L10n.locale)
        appearance = IMEThemeObservation { [weak self] theme in self?.theme = theme; self?.build() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in if self?.step == 0 { self?.build() } }
        build(); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) {
        if !completed, !InputMethodInstallation.shared.isRunningInstalled, !CommandLine.arguments.contains("--render-audit") { NSApp.terminate(nil) }
    }
    private func label(_ text: String, y: CGFloat, size: CGFloat = 14, height: CGFloat = 42, secondary: Bool = false, parent: NSView? = nil) {
        let value = FluentSelectableLabel(wrappingLabelWithString: text)
        value.theme = theme; value.font = IMEFont.font(ofSize: size); value.textColor = secondary ? theme.textSecondary : theme.textPrimary
        value.frame = NSRect(x: 0, y: y, width: 576, height: height); (parent ?? content).addSubview(value)
    }
    @discardableResult private func button(_ title: String, x: CGFloat = 0, y: CGFloat, width: CGFloat = 240, enabled: Bool = true, parent: NSView? = nil, action: @escaping () -> Void) -> FluentButton {
        let button = FluentButton(title: title); button.theme = theme; button.isEnabled = enabled && !busy; button.onClick = action
        button.frame = NSRect(x: x, y: y, width: width, height: 34); (parent ?? content).addSubview(button); return button
    }
    private func toggle(_ title: String, y: CGFloat, value: Bool, action: @escaping (Bool) -> Void) {
        let toggle = FluentToggle(title: title, isOn: value); toggle.theme = theme
        toggle.frame = NSRect(x: 0, y: y, width: 560, height: 32); toggle.onValueChanged = action; content.addSubview(toggle)
    }
    private func choice(y: CGFloat, selected: String, options: [(String, String)], action: @escaping (String) -> Void) {
        var selection: String? = selected
        let titles = Dictionary(uniqueKeysWithValues: options)
        let definition = FluentComboBox(options: options.map(\.0), selection: FluentBinding(get: { selection }, set: { selection = $0; if let value = $0 { action(value) } }), title: { titles[$0] ?? $0 })
        let view = definition._makeView(in: FluentRenderContext(theme: theme, locale: L10n.locale)); view.frame = NSRect(x: 0, y: y, width: 360, height: 32); content.addSubview(view)
    }
    private func build() {
        guard isWindowLoaded else { return }
        root.subviews.forEach { $0.removeFromSuperview() }; content.subviews.forEach { $0.removeFromSuperview() }
        root.layer?.backgroundColor = theme.windowBackground.cgColor
        let titlebar = FluentTitleBar(title: L10n.installTitle, heightMode: .compact, backgroundStyle: .transparent, windowControlsStyle: .windows,
            leftHeader: { FluentEmptyView() }, content: { FluentEmptyView() }, rightHeader: { FluentEmptyView() })
        let bar = titlebar._makeView(in: FluentRenderContext(theme: theme, locale: L10n.locale)); bar.frame = NSRect(x: 0, y: 0, width: 640, height: 40); root.addSubview(bar)
        let header = IMEFlippedView(frame: NSRect(x: 32, y: 68, width: 576, height: 130)); root.addSubview(header)
        label(L10n.setupStep(step + 1, 4), y: 0, size: 12, height: 24, secondary: true, parent: header)
        let titles = [L10n.installWelcome, L10n.installDictionaryTitle, L10n.setupModes, L10n.setupPrivacy]
        label(titles[step], y: 32, size: 25, height: 46, parent: header)
        label(step == 0 ? L10n.installIntro : step == 1 ? (installation.hasLocalDictionary ? L10n.installDictionaryFound : L10n.installDictionaryEmpty) : step == 2 ? L10n.fontHint : L10n.clipboardPrivacyHint,
              y: 82, height: 48, secondary: true, parent: header)
        content.frame = NSRect(x: 32, y: 216, width: 576, height: 372); root.addSubview(content)
        switch step {
        case 0:
            label(installation.isInstalled ? L10n.installInstalled : L10n.installNotInstalled, y: 0)
            button(busy ? L10n.installBusy : L10n.installAction, y: 36) { [weak self] in
                guard let self else { return }; self.busy = true; self.status = ""; self.build()
                self.installation.install { [weak self] result in
                    self?.busy = false
                    if case .failure(let error) = result { self?.status = L10n.installFailure(error.localizedDescription) }
                    self?.build()
                }
            }
            label(installation.isEnabled ? L10n.installEnabled : L10n.installNotEnabled, y: 94)
            button(L10n.installEnable, y: 130, enabled: installation.isInstalled) { [weak self] in
                do { try self?.installation.enable(); self?.status = "" } catch { self?.status = L10n.installFailure(error.localizedDescription) }
                self?.build()
            }
            button(L10n.advancedOpenKeyboard, y: 188, width: 300) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
            label(L10n.installEnableHint, y: 238, height: 62, secondary: true)
            button(L10n.updateTitle, x: 320, y: 188, width: 240) { [weak self] in if let root = self?.root { UpdateCoordinator.shared.present(in: root) } }
            label(L10n.installLocationHint, y: 308, size: 12, height: 48, secondary: true)
        case 1:
            if installation.hasLocalDictionary {
                for (index, title) in [L10n.installMerge, L10n.installReset].enumerated() {
                    let radio = FluentRadioButton(title: title, isSelected: resetDictionary == (index == 1), groupName: "ExistingDictionary")
                    radio.theme = theme; radio.frame = NSRect(x: 0, y: CGFloat(index * 116), width: 560, height: 34)
                    radio.onValueChanged = { [weak self] selected in if selected { self?.resetDictionary = index == 1 } }; content.addSubview(radio)
                    label(index == 0 ? L10n.installMergeHint : L10n.installResetHint, y: CGFloat(index * 116 + 44), height: 60, secondary: true)
                }
            } else { resetDictionary = false; label(L10n.installDictionaryEmpty, y: 0, height: 90) }
        case 2:
            for (index, mode) in InputMode.allCases.enumerated() {
                let check = FluentCheckBox(title: mode.title, isChecked: modes.contains(mode)); check.theme = theme
                check.frame = NSRect(x: 0, y: CGFloat(index * 44), width: 560, height: 30); check.isEnabled = modes.count > 1 || !check.isChecked
                check.onValueChanged = { [weak self] checked in
                    guard let self else { return }
                    self.modes = InputMode.normalized(checked ? self.modes + [mode] : self.modes.filter { $0 != mode })
                    if !self.modes.contains(self.defaultMode) { self.defaultMode = self.modes[0] }; self.build()
                }; content.addSubview(check)
            }
            label(L10n.generalDefaultModeChoice, y: 164)
            choice(y: 202, selected: defaultMode.rawValue, options: modes.map { ($0.rawValue, $0.title) }) { [weak self] in if let mode = InputMode(rawValue: $0) { self?.defaultMode = mode } }
        default:
            toggle(L10n.clipboardRecording, y: 0, value: recording) { [weak self] in self?.recording = $0 }
            label(L10n.clipboardRetention, y: 52)
            choice(y: 90, selected: String(retention), options: [("0", L10n.clipboardSession), ("900", L10n.clipboardMinutes15), ("1800", L10n.clipboardMinutes30), ("3600", L10n.clipboardHour1), ("86400", L10n.clipboardDay1), ("604800", L10n.clipboardDays7)]) { [weak self] in self?.retention = Int($0) ?? 1800 }
            label(InstallerLifecycle.isInstaller ? L10n.installCleanupHint : L10n.clipboardPinnedHint, y: 148, height: 70, secondary: true)
            toggle(L10n.appearanceAdvancedEffects, y: 248, value: effects) { [weak self] in self?.effects = $0 }
            toggle(L10n.modeIndicator, y: 300, value: indicator) { [weak self] in self?.indicator = $0 }
        }
        let statusLabel = FluentSelectableLabel(wrappingLabelWithString: status); statusLabel.theme = theme
        statusLabel.textColor = theme.textSecondary; statusLabel.font = IMEFont.font(ofSize: 12)
        statusLabel.frame = NSRect(x: 32, y: 588, width: 576, height: 30); root.addSubview(statusLabel)
        if step > 0 { button(L10n.setupPrevious, x: 32, y: 628, width: 160, parent: root) { [weak self] in self?.step -= 1; self?.status = ""; self?.build() } }
        button(step == 3 ? L10n.installFinish : L10n.setupNext, x: 348, y: 628, width: 260,
               enabled: step != 0 || (installation.isInstalled && installation.isEnabled), parent: root) { [weak self] in self?.advance() }
        root.layoutSubtreeIfNeeded()
    }
    private func advance() {
        guard step == 3 else { step += 1; status = ""; build(); return }
        busy = true; build()
        installation.complete(resetDictionary: resetDictionary, applyPreferences: { [self] in
            let p = Preferences.shared
            p.enabledInputModes = modes; p.defaultInputMode = defaultMode
            p.clipboardRetention = retention; p.clipboardRecording = recording
            p.advancedEffects = effects; p.showInputModeIndicator = indicator
            p.setupCompleted = true; UserDefaults.standard.synchronize()
        }) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success: self.completed = true; self.close(); self.onComplete()
            case .failure(let error):
                self.status = L10n.installFailure(error.localizedDescription); self.build()
                if InputMethodInstallation.shared.needsQuitAfterFailure { MaintenanceDialogs.showError(error, in: self.root) }
            }
        }
    }
}
