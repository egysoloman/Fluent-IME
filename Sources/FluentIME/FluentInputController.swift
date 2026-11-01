import AppKit
import InputMethodKit
import Carbon
import FluentIMECore

@objc(FluentInputController)
final class FluentInputController: IMKInputController {
    private var input: InputSession?
    private var activeClient: IMKTextInput?
    private var hadMarkedText = false
    private var markedPreedit = ""
    private var markedCursor = -1
    private let panel = CandidatePanel()
    private let emojiPanel = EmojiPanel()
    private var preferenceObserver: NSObjectProtocol?
    private var sourceObserver: NSObjectProtocol?
    private var anchorGeneration = 0
    private var compositionAnchor: NSRect?
    private var modeIndicatorRequest = ModeIndicatorRequest()

    override func activateServer(_ sender: Any!) {
        modeIndicatorRequest.deactivate()
        SystemInputModeIndicator.shared.panel.dismiss()
        invalidateAnchor()
        activeClient = sender as? IMKTextInput
        if input == nil {
            do { input = try InputSession(engine: Runtime.shared.engine.get(), options: { Preferences.shared.inputOptions }, ranker: NeuralRuntime.shared.ranker, languageOptions: { Preferences.shared.inputOptions(for: $0) }) }
            catch { NSLog("Fluent IME: %@", error.localizedDescription); return }
        }
        input?.resetContext()
        if let input { modeIndicatorRequest.activate(mode: input.mode) }
        input?.onCommit = { [weak self] text in
            guard let self else { return }
            self.activeClient?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.hadMarkedText = false
        }
        input?.onExpansionChange = { Preferences.shared.expandedCandidates = $0 }
        input?.onUpdate = { [weak self] composition in self?.update(composition) }
        panel.candidateView.onSelect = { [weak self] index in self?.input?.choose(index) }
        panel.candidateView.onPage = { [weak self] backward in self?.input?.page(backward: backward) }
        panel.candidateView.onEmoji = { [weak self] in self?.showEmoji() }
        panel.candidateView.onLayoutChange = { [weak self] in self?.input?.publish() }
        panel.candidateView.onLoadMore = { [weak self] in self?.input?.loadMoreCandidates() }
        panel.candidateView.onViewportChanged = { [weak self] start, columns in self?.input?.setCandidateViewport(start: start, columns: columns) }
        panel.candidateView.onInteraction = { [weak self] in self?.input?.lockRanking() }
        if preferenceObserver == nil {
            preferenceObserver = NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
                self?.input?.applyOptions(); self?.input?.publish()
            }
        }
        if sourceObserver == nil {
            sourceObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                guard let self, self.latinSourceIsSelected else { return }
                self.input?.finishRaw(); self.panel.orderOut(nil)
            }
        }
        // Focus alone must not produce a mode hint.
        if let input, let client = activeClient, let caret = caretRect(for: client) {
            SystemInputModeIndicator.shared.remember(input: input, caret: caret)
        }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue |
            NSEvent.EventTypeMask.leftMouseDown.rawValue | NSEvent.EventTypeMask.rightMouseDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        if event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown {
            modeIndicatorRequest.cancel()
            SystemInputModeIndicator.shared.panel.dismiss()
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown { input?.finish(); input?.resetContext(); return false }
        if input == nil { activateServer(sender) }
        activeClient = sender as? IMKTextInput
        return input?.handle(event) ?? false
    }

    private var latinSourceIsSelected: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let asciiPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        let ascii = Unmanaged<CFBoolean>.fromOpaque(asciiPointer).takeUnretainedValue()
        return !id.hasPrefix("org.fluentime.inputmethod.") && CFBooleanGetValue(ascii)
    }
    override func commitComposition(_ sender: Any!) {
        if latinSourceIsSelected || NSEvent.modifierFlags.contains(.capsLock) { input?.finishRaw() }
        else { input?.finish() }
    }
    override func deactivateServer(_ sender: Any!) {
        modeIndicatorRequest.deactivate()
        SystemInputModeIndicator.shared.panel.dismiss()
        if latinSourceIsSelected { input?.finishRaw() } else { input?.finish() }
        input?.resetContext()
        if let input, let client = activeClient, let caret = caretRect(for: client) {
            SystemInputModeIndicator.shared.remember(input: input, caret: caret)
        }
        panel.orderOut(nil)
        Preferences.shared.expandedCandidates = false
        activeClient = nil
        invalidateAnchor()
    }
    override func hidePalettes() {
        modeIndicatorRequest.cancel()
        Preferences.shared.expandedCandidates = false
        invalidateAnchor(); panel.orderOut(nil); SystemInputModeIndicator.shared.panel.dismiss()
    }
    override func inputControllerWillClose() {
        modeIndicatorRequest.deactivate()
        SystemInputModeIndicator.shared.panel.dismiss()
        input?.finish()
        emojiPanel.dismiss()
        panel.orderOut(nil)
        input = nil
        activeClient = nil
        invalidateAnchor()
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        preferenceObserver = nil
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
        sourceObserver = nil
    }
    deinit {
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
    }

    private func update(_ composition: Composition) {
        guard let client = activeClient else { return }
        if composition.isComposing { SystemInputModeIndicator.shared.panel.dismiss() }
        if let mode = input?.mode, let request = modeIndicatorRequest.changed(to: mode) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeClient === client,
                      self.modeIndicatorRequest.accepts(request) else { return }
                self.showModeIndicator()
            }
        }
        let changed = !hadMarkedText || markedPreedit != composition.preedit || markedCursor != composition.cursorUTF16
        anchorGeneration += 1
        let generation = anchorGeneration
        if (composition.isComposing || hadMarkedText) && changed {
            let attributed = NSAttributedString(string: composition.preedit, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue])
            client.setMarkedText(attributed,
                                 selectionRange: NSRange(location: composition.cursorUTF16, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            markedPreedit = composition.preedit; markedCursor = composition.cursorUTF16
        }
        hadMarkedText = composition.isComposing
        guard composition.isComposing else { invalidateAnchor(); panel.orderOut(nil); return }
        panel.candidateView.language = input?.mode ?? .simplifiedChinese
        if !changed, let anchor = compositionAnchor {
            // Candidate selection/paging does not alter the host's marked text.
            panel.present(composition, caret: anchor)
            return
        }
        // Query the IMK line rectangle after the host has applied marked text.
        // Do not display an unvalidated first frame and move it again three times.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.anchorGeneration == generation, self.activeClient === client,
                  let current = self.input?.composition, current.isComposing else { return }
            if let anchor = self.caretRect(for: client) { self.compositionAnchor = anchor }
            if let anchor = self.compositionAnchor { self.panel.present(current, caret: anchor) }
            else { self.panel.orderOut(nil) }
        }
    }

    private func invalidateAnchor() { anchorGeneration += 1; compositionAnchor = nil }
    private func caretRect(for client: IMKTextInput) -> NSRect? {
        CaretAnchor.resolve(marked: client.markedRange(), selected: client.selectedRange(), screens: NSScreen.screens.map(\.frame), documentRect: { range in
            var actual = NSRange(location: NSNotFound, length: 0)
            let rectangle = client.firstRect(forCharacterRange: range, actualRange: &actual)
            guard actual.location != NSNotFound, actual.location <= range.location,
                  range.location - actual.location <= actual.length else { return .zero }
            return rectangle
        }, inlineRect: {
            var rectangle = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rectangle)
            return rectangle
        })
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: L10n.appName)
        for mode in Preferences.shared.enabledInputModes {
            let item = menu.addItem(withTitle: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue; item.state = input?.mode == mode ? .on : .off
        }
        menu.addItem(.separator())
        let emoji = menu.addItem(withTitle: L10n.menuSymbols, action: #selector(openEmoji(_:)), keyEquivalent: "")
        emoji.target = self
        let settings = menu.addItem(withTitle: L10n.menuSettings, action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        return menu
    }
    @objc private func toggleMode(_ sender: Any?) { input?.toggleLanguage() }
    @objc private func selectMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = InputMode(rawValue: raw) { input?.selectMode(mode) }
    }
    private func showModeIndicator() {
        guard Preferences.shared.showInputModeIndicator, let input, let client = activeClient, let caret = caretRect(for: client) else { return }
        SystemInputModeIndicator.shared.remember(input: input, caret: caret)
        SystemInputModeIndicator.shared.showCurrent()
    }
    @objc private func openSettings(_ sender: Any?) { input?.finish(); Runtime.shared.showSettings() }
    @objc private func openEmoji(_ sender: Any?) { showEmoji() }
    private func showEmoji() {
        guard let target = activeClient ?? client() else { return }
        var caret = NSRect.zero
        _ = target.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        if caret.height <= 0 { caret = panel.isVisible ? panel.frame : NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20)) }
        input?.finish()
        // The nonactivating palette keeps the origin application active. Its callback is
        // invalidated on dismissal/app switching, and never re-targets a different IMK client.
        emojiPanel.present(near: caret) { text in
            target.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
}
