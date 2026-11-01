import AppKit
import Carbon
import FluentKit
import FluentIMECore

/// A nonactivating cursor accessory. Focus changes and typing dismiss it immediately.
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
    private var selector: NSView?
    private var generation = 0
    private(set) var expanded = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = false
        isFloatingPanel = true; level = IMEPopupLevel.emoji; shadow.level = level
        hidesOnDeactivate = false; animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        surface.wantsLayer = true; surface.layer?.masksToBounds = true
        surface.addSubview(material); contentView = surface
        observation = IMEThemeObservation { [weak self] _ in
            guard let self else { return }
            if !Preferences.shared.showInputModeIndicator { self.dismiss() }
            else if self.isVisible { self.rebuild() }
        }
    }
    func present(mode: InputMode, modes: [InputMode], near caret: NSRect, onSelect: @escaping (InputMode) -> Void) {
        guard Preferences.shared.showInputModeIndicator, !IsSecureEventInputEnabled(), caret.height > 0 else { dismiss(); return }
        let wasVisible = isVisible
        generation += 1
        self.mode = mode; self.modes = InputMode.normalized(modes); anchor = caret; selection = onSelect
        if !wasVisible { expanded = false }
        alphaValue = 1; rebuild()
        if !wasVisible { animateEntrance(fromWidth: nil) }
        scheduleDismiss(after: expanded ? 8 : 1.8)
    }
    private func scheduleDismiss(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.fadeOut() }
    }
    private func rebuild() {
        let theme = IMEThemeObservation.current
        material.fluentTheme = theme; material.isMaterialEnabled = Preferences.shared.advancedEffects && expanded
        material.fallbackColor = expanded ? theme.flyoutSurfaceFill : .clear; material.state = .active
        surface.layer?.borderWidth = expanded ? 0.5 : 0
        surface.layer?.borderColor = theme.surfaceStrokeFlyout.cgColor
        surface.layer?.cornerRadius = expanded ? 8 : 4
        let size = NSSize(width: expanded ? CGFloat(modes.count) * 42 + 8 : 38, height: expanded ? 36 : 28)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        setFrame(PanelPlacement.frame(size: size, caret: anchor, screen: screen.visibleFrame, gap: 5), display: false)
        material.frame = surface.bounds
        if expanded {
            surface.subviews.compactMap { $0 as? FluentButton }.forEach { $0.removeFromSuperview() }
            let definition = FluentSegmentedControl( modes.map(\.badge), selection: FluentBinding(
                get: { [weak self] in self?.modes.firstIndex(of: self?.mode ?? .simplifiedChinese) ?? 0 },
                set: { [weak self] index in
                    guard let self, self.modes.indices.contains(index) else { return }
                    self.mode = self.modes[index]
                    self.selection?(self.mode)
                    // Keep the control alive while its selection indicator slides.
                    self.scheduleDismiss(after: 1.2)
                }))
            let context = FluentRenderContext(theme: theme, locale: L10n.locale)
            if let selector { _ = definition._updateView(selector, in: context) }
            else { let view = definition._makeView(in: context); selector = view; surface.addSubview(view) }
            selector?.frame = surface.bounds.insetBy(dx: 4, dy: 4)
            selector?.setAccessibilityLabel(L10n.settingsModesTitle)
        } else {
            selector?.removeFromSuperview(); selector = nil
            surface.subviews.compactMap { $0 as? FluentButton }.forEach { $0.removeFromSuperview() }
            let button = FluentButton(title: mode.badge, role: .primary)
            button.theme = theme; button.refusesFirstResponder = true
            button.frame = NSRect(x: 1, y: 0, width: 36, height: 28)
            button.setAccessibilityLabel(L10n.modeIndicatorAccessibility(mode.title))
            button.onClick = { [weak self] in
                guard let self else { return }
                let width = self.frame.width
                self.expanded = true; self.rebuild(); self.animateEntrance(fromWidth: width); self.scheduleDismiss(after: 8)
            }
            surface.addSubview(button)
        }
        surface.layoutSubtreeIfNeeded()
        shadow.shadowView.theme = theme
        shadow.setFrame(CandidateChrome.shadowFrame(around: frame, flipped: false), display: false)
        if expanded { shadow.orderFrontRegardless() } else { shadow.orderOut(nil) }
        orderFrontRegardless()
        if expanded, !(childWindows?.contains(where: { $0 === shadow }) ?? false) { addChildWindow(shadow, ordered: .below) }
    }
    private func animateEntrance(fromWidth: CGFloat?) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = surface.layer else { return }
        let token = FluentMotion.controlFast
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = fromWidth == nil ? 0 : 0.65; fade.toValue = 1
        let slide = CABasicAnimation(keyPath: "transform.translation.y"); slide.fromValue = fromWidth == nil ? 4 : 0; slide.toValue = 0
        let group = CAAnimationGroup(); group.animations = [fade, slide]; group.duration = token.duration; group.timingFunction = token.curve.timingFunction
        layer.add(group, forKey: "FluentIME.Mode.Entrance")
        if let fromWidth {
            let mask = CAShapeLayer(); mask.path = CGPath(rect: surface.bounds, transform: nil); layer.mask = mask
            let reveal = CABasicAnimation(keyPath: "path")
            reveal.fromValue = CGPath(roundedRect: NSRect(x: 0, y: 0, width: fromWidth, height: surface.bounds.height), cornerWidth: 4, cornerHeight: 4, transform: nil)
            reveal.toValue = mask.path; reveal.duration = token.duration; reveal.timingFunction = token.curve.timingFunction
            mask.add(reveal, forKey: "FluentIME.Mode.Expansion")
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + token.duration) { [weak self] in
                guard let self, self.generation == current else { return }; self.surface.layer?.mask = nil
            }
        }
    }
    private func fadeOut() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { dismiss(); return }
        let current = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FluentMotion.controlFaster.duration
            self.animator().alphaValue = 0; self.shadow.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            self.dismiss()
        }
    }
    func dismiss() {
        generation += 1; timer?.invalidate(); timer = nil; selection = nil; expanded = false
        shadow.orderOut(nil); orderOut(nil); alphaValue = 1; shadow.alphaValue = 1
        surface.layer?.mask = nil; surface.layer?.removeAllAnimations(); selector?.removeFromSuperview(); selector = nil
    }
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
            guard id != self.previousSource else { return }
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
            // The input-session update or TIS notification displays the new
            // mode once. Do not re-open the panel from its own click callback.
        }
    }
}
