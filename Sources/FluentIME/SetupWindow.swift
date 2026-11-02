import AppKit
import FluentKit
import FluentIMECore

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let root = IMEFlippedView()
    private let content = IMEFlippedView()
    private let viewport = IMEFlippedView()
    private let pageMotion = IMEPageMotion()
    private var lastInstallState: [Bool] = []
    private let installation: SetupInstallation
    private let updates: (any IMEUpdateService)?
    private let onComplete: () -> Void
    private var checking = false
    private var dialog: NSView?
    private var theme = Preferences.shared.theme
    private var appearance: IMEThemeObservation?
    private var activeObserver: NSObjectProtocol?
    private var step = 0
    /// The dictionary choice only appears when there is a local dictionary to keep or reset.
    private var pages: [Int] { installation.hasLocalDictionary ? [0, 1, 2, 3, 4] : [0, 1, 3, 4] }
    private func page(_ offset: Int) -> Int {
        let list = pages, index = list.firstIndex(of: step) ?? 0
        return list[max(0, min(list.count - 1, index + offset))]
    }
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
    /// With `updates`, as when the installer is opened directly, the guide first checks
    /// whether a newer installer exists; only then does it look at the local installation.
    init(installation: SetupInstallation = InputMethodInstallation.shared, updates: (any IMEUpdateService)? = nil, onComplete: @escaping () -> Void = {}) {
        self.installation = installation; self.updates = updates; self.onComplete = onComplete
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 612), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.installTitle; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; window.contentView = root; root.wantsLayer = true
        root.fluentSetLocalization(locale: L10n.locale)
        appearance = IMEThemeObservation { [weak self] theme in self?.theme = theme; self?.build() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in guard let self, self.step <= 1, !self.busy, !self.checking else { return }; if self.lastInstallState != [self.installation.isInstalled, self.installation.isEnabled] { self.build() } }
        build(); window.center()
        if updates != nil { checkForUpdates() }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func checkForUpdates() {
        guard let updates else { return }
        checking = true; build()
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        Task { @MainActor [weak self] in
            do {
                let release = try await updates.latest(channel: .stable)
                guard let self else { return }
                if let release, release.isNewer(than: current) {
                    self.ask(title: L10n.setupOutdatedTitle, message: L10n.setupOutdated(current, release.version), primary: L10n.setupDownloadLatest) {
                        NSWorkspace.shared.open(release.pageURL); NSApp.terminate(nil)
                    }
                } else { self.checking = false; self.build() }
            } catch {
                guard let self else { return }
                let offline = error is URLError
                self.ask(title: offline ? L10n.setupOfflineTitle : L10n.updateCheckFailed, message: offline ? L10n.setupOffline : L10n.setupCheckFailed, primary: L10n.setupRetry) { [weak self] in self?.checkForUpdates() }
            }
        }
    }
    private func ask(title: String, message: String, primary: String, onPrimary: @escaping () -> Void) {
        dialog = MaintenanceDialogs.choose(in: root, title: title, message: message, primary: primary, close: L10n.setupContinue,
            onPrimary: { [weak self] in self?.dialog = nil; onPrimary() },
            onClose: { [weak self] in self?.dialog = nil; self?.checking = false; self?.build() })
    }
    deinit { if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) {
        if !completed, !InputMethodInstallation.shared.isRunningInstalled, !CommandLine.arguments.contains("--render-audit") { NSApp.terminate(nil) }
    }
    @discardableResult private func label(_ text: String, x: CGFloat = 0, y: CGFloat, width: CGFloat = 544, size: CGFloat = 14, height: CGFloat = 42, secondary: Bool = false, parent: NSView? = nil) -> NSTextField {
        let value = FluentSelectableLabel(wrappingLabelWithString: text)
        value.theme = theme; value.font = IMEFont.font(ofSize: size); value.textColor = secondary ? theme.textSecondary : theme.textPrimary
        value.frame = NSRect(x: x, y: y, width: width, height: height); (parent ?? content).addSubview(value)
        return value
    }
    @discardableResult private func button(_ title: String, x: CGFloat = 0, y: CGFloat, width: CGFloat = 192, enabled: Bool = true, primary: Bool = false, parent: NSView? = nil, action: @escaping () -> Void) -> FluentButton {
        let button = FluentButton(title: title, role: primary ? .primary : .standard); button.theme = theme; button.isEnabled = enabled && !busy; button.onClick = action
        button.frame = NSRect(x: x, y: y, width: width, height: 34); (parent ?? content).addSubview(button); return button
    }
    private func card(x: CGFloat = 0, y: CGFloat, width: CGFloat = 544, height: CGFloat) {
        let view = NSView(frame: NSRect(x: x, y: y, width: width, height: height)); view.wantsLayer = true
        view.layer?.cornerRadius = 8; view.layer?.borderWidth = 0.5
        view.layer?.borderColor = theme.surfaceStrokeFlyout.cgColor
        view.layer?.backgroundColor = (theme.isDark ? NSColor.white.withAlphaComponent(0.035) : NSColor.white.withAlphaComponent(0.65)).cgColor
        content.addSubview(view)
    }
    private func toggle(_ title: String, y: CGFloat, value: Bool, action: @escaping (Bool) -> Void) {
        let toggle = FluentToggle(title: title, isOn: value); toggle.theme = theme
        toggle.frame = NSRect(x: 16, y: y, width: 512, height: 32); toggle.onValueChanged = action; content.addSubview(toggle)
    }
    private func choice(x: CGFloat = 0, y: CGFloat, width: CGFloat = 300, selected: String, options: [(String, String)], action: @escaping (String) -> Void) {
        var selection: String? = selected
        let titles = Dictionary(uniqueKeysWithValues: options)
        let definition = FluentComboBox(options: options.map(\.0), selection: FluentBinding(get: { selection }, set: { selection = $0; if let value = $0 { action(value) } }), title: { titles[$0] ?? $0 })
        let view = definition._makeView(in: FluentRenderContext(theme: theme, locale: L10n.locale)); view.frame = NSRect(x: x, y: y, width: width, height: 32); content.addSubview(view)
    }
    private func navigate(_ destination: Int) {
        guard !busy, (0...4).contains(destination), destination != step else { return }
        let snapshot = pageMotion.capture(viewport), backward = destination < step
        step = destination; status = ""; build()
        pageMotion.play(snapshot, in: viewport, content: content, backward: backward, navigation: true)
    }
    private func build() {
        guard isWindowLoaded else { return }
        pageMotion.cancel()
        root.subviews.forEach { $0.removeFromSuperview() }; content.subviews.forEach { $0.removeFromSuperview() }
        root.layer?.backgroundColor = theme.windowBackground.cgColor
        let titlebar = FluentTitleBar(title: L10n.installTitle, heightMode: .compact, backgroundStyle: .transparent, windowControlsStyle: .windows,
            leftHeader: { FluentEmptyView() }, content: { FluentEmptyView() }, rightHeader: { FluentEmptyView() })
        let bar = titlebar._makeView(in: FluentRenderContext(theme: theme, locale: L10n.locale)); bar.frame = NSRect(x: 0, y: 0, width: 640, height: 40); root.addSubview(bar)
        let shown = pages, position = shown.firstIndex(of: step) ?? 0
        label(L10n.setupStep(position + 1, shown.count), x: 48, y: 62, width: 220, size: 12, height: 20, secondary: true, parent: root)
        let markerWidth = (544 - 11 * CGFloat(shown.count - 1)) / CGFloat(shown.count)
        for index in shown.indices {
            let marker = NSView(frame: NSRect(x: 48 + CGFloat(index) * (markerWidth + 11), y: 94, width: markerWidth, height: 3))
            marker.wantsLayer = true; marker.layer?.cornerRadius = 1.5
            marker.layer?.backgroundColor = (index <= position ? theme.accent : theme.surfaceStrokeFlyout).cgColor; root.addSubview(marker)
        }
        viewport.frame = NSRect(x: 48, y: 124, width: 544, height: 378)
        viewport.wantsLayer = true; viewport.layer?.masksToBounds = true; root.addSubview(viewport)
        content.frame = viewport.bounds; viewport.addSubview(content)
        let titles = [L10n.installWelcome, L10n.installEnable, L10n.settingsDictionaryTitle, L10n.setupModes, L10n.setupPrivacy]
        let title = label(titles[step], y: 0, size: 26, height: 40); title.font = IMEFont.font(ofSize: 26, weight: .semibold)
        let descriptions = [L10n.installIntro, L10n.installEnableHint,
            installation.hasLocalDictionary ? L10n.installDictionaryFound : L10n.installDictionaryEmpty,
            L10n.settingsModesDetail, L10n.clipboardPrivacyHint]
        label(descriptions[step], y: 52, size: 13, height: 56, secondary: true)
        lastInstallState = [installation.isInstalled, installation.isEnabled]
        switch step {
        case 0:
            card(y: 128, height: 116)
            if checking {
                label(L10n.updateChecking, x: 20, y: 148, width: 504, size: 16, height: 28)
                let progress = FluentProgressBar(value: 0); progress.theme = theme; progress.isIndeterminate = true
                progress.frame = NSRect(x: 20, y: 196, width: 504, height: 4); content.addSubview(progress)
            } else {
                let state = installation.newerInstalledVersion.map(L10n.installNewerInstalled) ?? (installation.isInstalled ? L10n.installInstalled : L10n.installNotInstalled)
                label(state, x: 20, y: 148, width: 504, size: 16, height: 28)
                label(L10n.installLocationHint, x: 20, y: 188, width: 504, size: 13, height: 44, secondary: true)
            }
        case 1:
            card(y: 128, height: 76)
            label(installation.isEnabled ? L10n.installEnabled : L10n.installNotEnabled, x: 20, y: 150, width: 504, size: 16, height: 30)
            button(L10n.advancedOpenKeyboard, y: 236, width: 300) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
        case 2:
            if installation.hasLocalDictionary {
                for (index, title) in [L10n.installMerge, L10n.installReset].enumerated() {
                    let y = CGFloat(index * 116 + 120)
                    card(y: y, height: 104)
                    let radio = FluentRadioButton(title: title, isSelected: resetDictionary == (index == 1), groupName: "ExistingDictionary")
                    radio.theme = theme; radio.frame = NSRect(x: 16, y: y + 12, width: 512, height: 32)
                    radio.onValueChanged = { [weak self] selected in if selected { self?.resetDictionary = index == 1 } }; content.addSubview(radio)
                    label(index == 0 ? L10n.installMergeHint : L10n.installResetHint, x: 44, y: y + 52, width: 480, size: 13, height: 44, secondary: true)
                }
            } else { resetDictionary = false }
        case 3:
            for (index, mode) in InputMode.allCases.enumerated() {
                let y = CGFloat(index * 54 + 112)
                card(y: y, height: 46)
                let check = FluentCheckBox(title: mode.title, isChecked: modes.contains(mode)); check.theme = theme
                check.frame = NSRect(x: 16, y: y + 7, width: 512, height: 32); check.isEnabled = modes.count > 1 || !check.isChecked
                check.onValueChanged = { [weak self] checked in
                    guard let self else { return }
                    self.modes = InputMode.normalized(checked ? self.modes + [mode] : self.modes.filter { $0 != mode })
                    if !self.modes.contains(self.defaultMode) { self.defaultMode = self.modes[0] }; self.build()
                }; content.addSubview(check)
            }
            label(L10n.generalDefaultModeChoice, y: 288, width: 244, height: 32)
            choice(x: 280, y: 280, width: 264, selected: defaultMode.rawValue, options: modes.map { ($0.rawValue, $0.title) }) { [weak self] in if let mode = InputMode(rawValue: $0) { self?.defaultMode = mode } }
        default:
            card(y: 112, height: 144)
            toggle(L10n.clipboardRecording, y: 124, value: recording) { [weak self] in self?.recording = $0 }
            label(L10n.clipboardRetention, x: 16, y: 174, width: 230, size: 13, height: 28)
            choice(x: 280, y: 166, width: 248, selected: String(retention), options: [("0", L10n.clipboardSession), ("900", L10n.clipboardMinutes15), ("1800", L10n.clipboardMinutes30), ("3600", L10n.clipboardHour1), ("86400", L10n.clipboardDay1), ("604800", L10n.clipboardDays7)]) { [weak self] in self?.retention = Int($0) ?? 1800 }
            label(L10n.clipboardPinnedHint, x: 16, y: 210, width: 512, size: 12, height: 40, secondary: true)
            card(y: 268, height: 92)
            toggle(L10n.appearanceAdvancedEffects, y: 276, value: effects) { [weak self] in self?.effects = $0 }
            toggle(L10n.modeIndicator, y: 318, value: indicator) { [weak self] in self?.indicator = $0 }
        }
        label(status, x: 48, y: 506, width: 544, size: 12, height: 36, secondary: true, parent: root)
        let separator = NSView(frame: NSRect(x: 0, y: 548, width: 640, height: 0.5)); separator.wantsLayer = true; separator.layer?.backgroundColor = theme.surfaceStrokeFlyout.cgColor; root.addSubview(separator)
        if step > 0 { button(L10n.setupPrevious, x: 48, y: 564, width: 124, parent: root) { [weak self] in guard let self else { return }; self.navigate(self.page(-1)) } }
        let actionTitle = step == 0 && !installation.isInstalled ? (busy ? L10n.installBusy : L10n.installAction) : step == 1 && !installation.isEnabled ? L10n.installEnable : step == 4 ? L10n.installFinish : L10n.setupNext
        button(actionTitle, x: 352, y: 564, width: 240, enabled: !checking, primary: true, parent: root) { [weak self] in self?.advance() }
        if let dialog { dialog.frame = root.bounds; root.addSubview(dialog) }
        root.layoutSubtreeIfNeeded()
    }
    private func advance() {
        if step == 0, !installation.isInstalled {
            busy = true; status = ""; build()
            installation.install { [weak self] result in
                guard let self else { return }; self.busy = false
                switch result {
                case .success: self.navigate(1)
                case .failure(let error): self.status = L10n.installFailure(error.localizedDescription); self.build()
                }
            }
            return
        }
        if step == 1, !installation.isEnabled {
            do { try installation.enable() }
            catch { status = L10n.installFailure(error.localizedDescription); build(); return }
            guard installation.isEnabled else { status = L10n.installEnableHint; build(); return }
        }
        guard step == 4 else { navigate(page(1)); return }
        busy = true; build()
        installation.complete(resetDictionary: resetDictionary && installation.hasLocalDictionary, applyPreferences: { [self] in
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
