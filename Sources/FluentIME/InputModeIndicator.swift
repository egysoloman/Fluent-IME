import AppKit
import Carbon
import FluentKit
import FluentIMECore

private final class ModeBadgeButton: NSButton {
    var selected = false
    var theme = IMEThemeObservation.current
    var invoke: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(mode: InputMode) {
        super.init(frame: .zero)
        title = mode.badge; isBordered = false; target = self; action = #selector(clicked)
        setAccessibilityLabel(mode.title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func clicked() { invoke?() }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            theme.accent.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: IMEFont.font(ofSize: 13, weight: .semibold), .foregroundColor: selected ? NSColor.white : theme.textPrimary]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
    }
}

/// Small nonactivating cursor accessory. Clicking expands only the enabled modes.
final class InputModePanel: NSPanel {
    private let surface = NSView()
    private let material = FluentMaterialView(material: .nativeAcrylic)
    private let shadow = CandidateShadowPanel()
    private var timer: Timer?
    private var observation: IMEThemeObservation?
    private var anchor = NSRect.zero
    private var mode: InputMode = .simplifiedChinese
    private var modes: [InputMode] = []
    private var selection: ((InputMode) -> Void)?
    private(set) var expanded = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = false
        isFloatingPanel = true; level = IMEPopupLevel.emoji; shadow.level = level
        hidesOnDeactivate = false; animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        surface.wantsLayer = true; surface.layer?.cornerRadius = 14; surface.layer?.masksToBounds = true
        surface.addSubview(material); contentView = surface
        observation = IMEThemeObservation { [weak self] _ in
            guard let self else { return }
            if !Preferences.shared.showInputModeIndicator { self.dismiss() }
            else if self.isVisible { self.rebuild() }
        }
    }
    func present(mode: InputMode, modes: [InputMode], near caret: NSRect, onSelect: @escaping (InputMode) -> Void) {
        guard Preferences.shared.showInputModeIndicator, !IsSecureEventInputEnabled(), caret.height > 0 else { dismiss(); return }
        self.mode = mode; self.modes = InputMode.normalized(modes); anchor = caret; selection = onSelect
        expanded = false; rebuild(); scheduleDismiss(after: 1.8)
    }
    private func scheduleDismiss(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.dismiss() }
    }
    private func rebuild() {
        let theme = IMEThemeObservation.current
        let shown = expanded ? modes : [mode]
        surface.subviews.filter { $0 !== material }.forEach { $0.removeFromSuperview() }
        material.fluentTheme = theme; material.isMaterialEnabled = Preferences.shared.advancedEffects && expanded
        material.fallbackColor = expanded ? theme.flyoutSurfaceFill : .clear; material.state = .active
        surface.layer?.borderWidth = expanded ? 0.5 : 0
        surface.layer?.borderColor = theme.surfaceStrokeFlyout.cgColor
        let size = NSSize(width: CGFloat(shown.count)*34 + (expanded ? 4 : 0), height: 28)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        setFrame(PanelPlacement.frame(size: size, caret: anchor, screen: screen.visibleFrame, gap: 5), display: false)
        material.frame = surface.bounds
        for (index, value) in shown.enumerated() {
            let button = ModeBadgeButton(mode: value)
            button.theme = theme; button.selected = value == mode
            button.frame = NSRect(x: CGFloat(index)*34 + (expanded ? 2 : 0), y: 0, width: 34, height: 28)
            button.setAccessibilityLabel(expanded ? value.title : L10n.modeIndicatorAccessibility(value.title))
            button.invoke = { [weak self] in
                guard let self else { return }
                if !self.expanded { self.expanded = true; self.rebuild(); self.scheduleDismiss(after: 8) }
                else { let action = self.selection; self.dismiss(); action?(value) }
            }
            surface.addSubview(button)
        }
        shadow.shadowView.theme = theme
        shadow.setFrame(CandidateChrome.shadowFrame(around: frame, flipped: false), display: false)
        if expanded { shadow.orderFrontRegardless() } else { shadow.orderOut(nil) }
        orderFrontRegardless()
        if expanded, !(childWindows?.contains(where: { $0 === shadow }) ?? false) { addChildWindow(shadow, ordered: .below) }
    }
    func dismiss() { timer?.invalidate(); timer = nil; selection = nil; expanded = false; shadow.orderOut(nil); orderOut(nil) }
    deinit { timer?.invalidate() }
}

/// Input-source notifications only; no keyboard tap or accessibility permission.
final class SystemInputModeIndicator {
    static let shared = SystemInputModeIndicator()
    let panel = InputModePanel()
    private weak var input: InputSession?
    private var lastMode: InputMode = .simplifiedChinese
    private var requestedMode: InputMode?
    private var caret: NSRect?
    private var ownerPID: pid_t?
    private var previousSource = ""
    private var sourceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private init() {
        previousSource = sourceID
        sourceObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let id = self.sourceID, fromFluent = self.previousSource.hasPrefix("org.fluentime.")
            self.previousSource = id
            if fromFluent || id.hasPrefix("org.fluentime.") { self.showCurrent() }
            else { self.panel.dismiss() }
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier != self.ownerPID else { return }
            self.panel.dismiss(); self.input = nil; self.caret = nil; self.requestedMode = nil
        }
    }
    private var sourceID: String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    func remember(input: InputSession, caret: NSRect) {
        guard Preferences.shared.showInputModeIndicator else { panel.dismiss(); return }
        self.input = input; self.caret = caret; ownerPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if sourceID.hasPrefix("org.fluentime."), let mode = requestedMode {
            requestedMode = nil
            input.selectMode(mode)
        }
        lastMode = input.mode
    }
    func showCurrent() {
        guard let caret, ownerPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else { panel.dismiss(); return }
        let isFluent = sourceID.hasPrefix("org.fluentime.")
        if !isFluent {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable),
                  CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()) else { panel.dismiss(); return }
        }
        panel.present(mode: isFluent ? (requestedMode ?? input?.mode ?? lastMode) : .english, modes: Preferences.shared.enabledInputModes, near: caret) { [weak self] mode in
            guard let self, self.ownerPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            self.lastMode = mode
            self.input?.selectMode(mode)
            if !self.sourceID.hasPrefix("org.fluentime."), mode.isChinese {
                self.requestedMode = mode
                let filter = [kTISPropertyInputSourceID as String: "org.fluentime.inputmethod.FluentIME.Hans"] as CFDictionary
                let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
                if let source = sources.first {
                    if TISSelectInputSource(source) != noErr { self.requestedMode = nil }
                } else { self.requestedMode = nil }
            }
            self.showCurrent()
        }
    }
}
