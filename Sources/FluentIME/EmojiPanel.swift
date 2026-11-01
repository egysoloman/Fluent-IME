import AppKit
import FluentKit
import FluentIMECore
import UniformTypeIdentifiers

private final class SymbolButton: NSButton {
    let entry: SymbolEntry
    var invoke: (() -> Void)?
    var selectionHighlighted = false { didSet { needsDisplay = true } }
    var theme = FluentTheme.current
    private var hovered = false
    // Each symbol grid owns one hovered tile. Scrolling or rebuilding tracking areas can
    // omit an exit event, so a new entry explicitly releases the previous tile.
    private static let hoverOwners = NSMapTable<NSView, SymbolButton>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(_ entry: SymbolEntry) {
        self.entry = entry
        super.init(frame: .zero)
        isBordered = false; title = entry.text
        target = self; action = #selector(clicked)
        toolTip = entry.name; setAccessibilityLabel(entry.name + " " + entry.text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func clicked() { invoke?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        if hovered {
            let point = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            if isHiddenOrHasHiddenAncestor || point.map({ !visibleRect.contains($0) }) != false {
                setHovered(false)
            }
        }
    }
    private func setHovered(_ value: Bool) {
        if let parent = superview {
            if value {
                if let previous = Self.hoverOwners.object(forKey: parent), previous !== self { previous.setHovered(false) }
                Self.hoverOwners.setObject(self, forKey: parent)
            } else if Self.hoverOwners.object(forKey: parent) === self {
                Self.hoverOwners.removeObject(forKey: parent)
            }
        }
        guard hovered != value else { return }
        hovered = value; needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview !== superview { setHovered(false) }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || selectionHighlighted || window?.firstResponder === self {
            theme.subtleFillSecondary.setFill()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            if hovered { border.fill() }
            if selectionHighlighted || window?.firstResponder === self { theme.textPrimary.setStroke(); border.lineWidth = 1.8; border.stroke() }
        }
        if let image = FluentEmojiImage.image(for: entry.text) {
            FluentIconSource.image(image).draw(in: NSRect(x: (bounds.width - 32) / 2, y: (bounds.height - 32) / 2, width: 32, height: 32), color: theme.textPrimary)
            return
        }
        let size: CGFloat = entry.kind == .emoji ? 32 : entry.kind == .symbol ? 22 : 13
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: IMEFont.font(ofSize: size), .foregroundColor: theme.textPrimary, .paragraphStyle: paragraph]
        let height = (entry.text as NSString).size(withAttributes: attrs).height
        (entry.text as NSString).draw(in: NSRect(x: 5, y: (bounds.height - height) / 2, width: bounds.width - 10, height: height), withAttributes: attrs)
    }
}

final class EmojiPanelView: NSView, NSSearchFieldDelegate {
    private let material = FluentMaterialView(material: .mica)
    private let titleLabel = NSTextField(labelWithString: L10n.symbolsTitle)
    private let closeButton = makeChromeButton(.close, label: L10n.symbolsClose)
    let searchField = FluentSearchTextField(placeholder: L10n.symbolsSearch)
    private let indicator = NSView()
    private let scroll = NSScrollView()
    private let document = IMEFlippedView()
    private var tabs: [FluentButton] = []
    private let glyphs: [IMEGlyph] = [.palette, .smile, .gif, .kaomoji, .symbols, .clipboard]
    private let tabNames = [L10n.symbolsFavorites, L10n.symbolsEmoji, "GIF", L10n.symbolsKaomoji, L10n.symbolsSymbols, L10n.symbolsClipboard]
    private var itemButtons: [SymbolButton] = []
    private var theme = FluentTheme.current
    private var appearanceObserver: IMEThemeObservation?
    private var selectedIndex = 0
    private var selectedTab = 0
    private var columnCount = 6
    private let clipboard: ClipboardHistory
    private let gifs = GIFLibrary.shared
    private var clipboardObserver: NSObjectProtocol?
    private var mediaStatus = ""
    private(set) var isChoosingGIF = false
    private let pageMotion = IMEPageMotion()
    var onInsert: ((String) -> Void)?
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }

    override convenience init(frame frameRect: NSRect) { self.init(frame: frameRect, clipboard: .shared) }
    init(frame frameRect: NSRect, clipboard: ClipboardHistory) {
        self.clipboard = clipboard
        super.init(frame: frameRect)
        fluentSetLocalization(locale: L10n.locale)
        wantsLayer = true; layer?.cornerRadius = 9; layer?.masksToBounds = true
        addSubview(material)
        titleLabel.font = IMEFont.font(ofSize: 14); addSubview(titleLabel)
        closeButton.onClick = { [weak self] in self?.onClose?() }; addSubview(closeButton)
        for (index, glyph) in glyphs.enumerated() {
            let button = makeChromeButton(glyph, label: tabNames[index])
            button.onClick = { [weak self] in self?.selectTab(index) }
            tabs.append(button); addSubview(button)
        }
        indicator.wantsLayer = true; indicator.layer?.cornerRadius = 1.5; addSubview(indicator)
        searchField.delegate = self; searchField.setAccessibilityLabel(L10n.symbolsSearchAccessibility)
        searchField.onCancel = { [weak self] in self?.onClose?() }
        addSubview(searchField)
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document; addSubview(scroll)
        applyTheme(); reload()
        appearanceObserver = IMEThemeObservation { [weak self] _ in self?.applyTheme() }
        clipboardObserver = NotificationCenter.default.addObserver(forName: ClipboardHistory.changed, object: clipboard, queue: .main) { [weak self] _ in
            guard let self, self.selectedTab == 5, self.window?.isVisible == true else { return }
            self.reload(resetScroll: false)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare() {
        clipboard.poll()
        mediaStatus = ""; selectedTab = 0; searchField.stringValue = ""; searchField.isEnabled = true
        applyTheme(); reload(); needsLayout = true
    }
    func applyTheme() {
        let updated = IMEThemeObservation.current
        if updated != theme { pageMotion.cancel() }
        theme = updated
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        material.fluentTheme = theme
        layer?.borderWidth = 0.5
        layer?.borderColor = theme.surfaceStrokeFlyout.cgColor
        titleLabel.textColor = theme.textPrimary
        closeButton.theme = theme; closeButton.image = IMEGlyph.close.image(color: theme.textPrimary)
        for (index, button) in tabs.enumerated() {
            button.theme = theme
            button.image = glyphs[index].image(color: button.isEnabled ? theme.textPrimary : theme.textDisabled)
        }
        indicator.layer?.backgroundColor = theme.accent.cgColor
        searchField.theme = theme
        material.materialStyle = .nativeAcrylic
        material.isMaterialEnabled = Preferences.shared.advancedEffects
        material.state = .active
        material.fallbackColor = theme.isDark ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.17, alpha: 1) : NSColor(srgbRed: 240/255, green: 240/255, blue: 240/255, alpha: 1)
        func refreshInk(_ view: NSView) {
            if let button = view as? SymbolButton { button.theme = theme }
            if let button = view as? GIFPreviewButton { button.theme = theme }
            if let card = view as? ClipboardCard { card.theme = theme }
            if let button = view as? FluentButton { button.theme = theme }
            if let field = view as? FluentTextField { field.theme = theme }
            else if let label = view as? NSTextField, !label.isEditable {
                label.textColor = (label.font?.pointSize ?? 14) < 16 ? theme.textSecondary : theme.textPrimary
            }
            view.needsDisplay = true
            view.subviews.forEach(refreshInk)
        }
        refreshInk(document)
        needsDisplay = true
    }
    override func layout() {
        super.layout(); material.frame = bounds
        titleLabel.frame = NSRect(x: 14, y: 10, width: 250, height: 22)
        closeButton.frame = NSRect(x: bounds.width - 30, y: 5, width: 22, height: 22)
        for (index, tab) in tabs.enumerated() { tab.frame = NSRect(x: 22 + CGFloat(index) * 41, y: 43, width: 28, height: 28) }
        indicator.frame = NSRect(x: 28 + CGFloat(selectedTab) * 41, y: 76, width: 16, height: 3)
        searchField.frame = NSRect(x: 17, y: 96, width: bounds.width - 34, height: 32)
        searchField.isHidden = selectedTab == 5
        let top: CGFloat = selectedTab == 5 ? 98 : 148
        scroll.frame = NSRect(x: 16, y: top, width: bounds.width - 24, height: bounds.height - top - 2)
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func selectTab(_ index: Int) {
        let snapshot = index != selectedTab ? pageMotion.capture(scroll.contentView) : nil
        let backward = index < selectedTab
        selectedTab = index; searchField.stringValue = ""; mediaStatus = ""
        searchField.isEnabled = index != 5
        reload(); needsLayout = true
        layoutSubtreeIfNeeded()
        pageMotion.play(snapshot, in: scroll.contentView, content: document, backward: backward)
    }
    func moveSelection(by delta: Int) {
        guard !itemButtons.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), itemButtons.count - 1)
        for (index, button) in itemButtons.enumerated() { button.selectionHighlighted = index == selectedIndex }
        document.scrollToVisible(itemButtons[selectedIndex].frame)
    }
    func moveRow(backward: Bool) {
        guard itemButtons.indices.contains(selectedIndex) else { return }
        let current = itemButtons[selectedIndex].frame
        let options = itemButtons.enumerated().filter { backward ? $0.element.frame.midY < current.midY : $0.element.frame.midY > current.midY }
        let next = options.min { lhs, rhs in
            let a = lhs.element.frame; let b = rhs.element.frame
            let ay = abs(a.midY - current.midY); let by = abs(b.midY - current.midY)
            return ay == by ? abs(a.midX - current.midX) < abs(b.midX - current.midX) : ay < by
        }
        if let next { moveSelection(by: next.offset - selectedIndex) }
    }
    func insertSelection() { if itemButtons.indices.contains(selectedIndex) { select(itemButtons[selectedIndex].entry) } }

    private func select(_ entry: SymbolEntry) {
        let existing = UserDefaults.standard.stringArray(forKey: "recentSymbols") ?? []
        UserDefaults.standard.set(SymbolCatalog.recent(afterSelecting: entry.text, existing: existing), forKey: "recentSymbols")
        onInsert?(entry.text)
    }
    private func label(_ text: String, y: CGFloat, size: CGFloat = 14) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = size < 16 ? theme.textSecondary : theme.textPrimary
        label.font = IMEFont.font(ofSize: size)
        label.frame = NSRect(x: 0, y: y, width: 318, height: size < 16 ? 58 : 27)
        document.addSubview(label)
    }
    private func sectionArrow(at y: CGFloat, tab: Int) {
        let button = makeChromeButton(.chevronRight, label: tab == 1 ? L10n.symbolsMoreEmoji : "GIF")
        button.fluentStyle = IMECompactButtonStyle(); button.theme = theme
        button.frame = NSRect(x: 303, y: y - 2, width: 24, height: 24)
        button.onClick = { [weak self] in self?.selectTab(tab) }
        document.addSubview(button)
    }
    @discardableResult private func grid(_ entries: [SymbolEntry], y: CGFloat, columns: Int = 6) -> CGFloat {
        columnCount = columns
        let width: CGFloat = 328 / CGFloat(columns)
        let height: CGFloat = columns == 3 ? 48 : 58
        for (index, entry) in entries.enumerated() {
            let button = SymbolButton(entry); button.theme = theme
            button.frame = NSRect(x: CGFloat(index % columns) * width, y: y + CGFloat(index / columns) * height, width: width, height: height)
            button.invoke = { [weak self] in self?.select(entry) }
            document.addSubview(button); itemButtons.append(button)
        }
        return y + ceil(CGFloat(entries.count) / CGFloat(columns)) * height
    }
    private func reload(resetScroll: Bool = true) {
        let offset = scroll.contentView.bounds.origin
        defer { if !resetScroll { scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset.y, max(0, document.frame.height - scroll.contentView.bounds.height)))) } }
        document.subviews.forEach { $0.removeFromSuperview() }; itemButtons = []; selectedIndex = 0
        scroll.contentView.scroll(to: .zero)
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var height: CGFloat = 310
        if selectedTab == 5 {
            height = buildClipboard()
        } else if selectedTab == 2 {
            height = buildGIFs(query: query)
        } else if !query.isEmpty {
            let kind: SymbolKind? = selectedTab == 1 ? .emoji : selectedTab == 3 ? .kaomoji : selectedTab == 4 ? .symbol : nil
            let results = SymbolCatalog.search(query, kind: kind)
            label(results.isEmpty ? L10n.symbolsNoResults : L10n.symbolsResults, y: 0)
            if results.isEmpty { label(L10n.symbolsSearchHint, y: 42, size: 13) }
            let wide = results.contains { $0.kind == .kaomoji }
            height = max(310, grid(results, y: 32, columns: wide ? 3 : 6))
        } else if selectedTab == 0 {
            let recent = UserDefaults.standard.stringArray(forKey: "recentSymbols") ?? []
            if recent.isEmpty {
                label(L10n.symbolsEmoji, y: 0)
                sectionArrow(at: 0, tab: 1)
                let bottom = grid(Array(SymbolCatalog.search("", kind: .emoji).prefix(12)), y: 32)
                label("GIF", y: bottom + 22)
                sectionArrow(at: bottom + 22, tab: 2)
                mediaAction(L10n.gifAdd, x: 0, y: bottom + 52, width: 104) { [weak self] in self?.selectTab(2); self?.addGIFs() }
                label(L10n.symbolsKaomoji, y: bottom + 100)
                height = grid(Array(SymbolCatalog.search("", kind: .kaomoji).prefix(6)), y: bottom + 132, columns: 3) + 10
            } else {
                label(L10n.symbolsRecent, y: 0)
                let entries = recent.compactMap { text in SymbolCatalog.entries.first { $0.text == text } }
                let bottom = grid(Array(entries.prefix(12)), y: 32, columns: entries.contains { $0.kind == .kaomoji } ? 3 : 6)
                label(L10n.symbolsEmoji, y: bottom + 22)
                height = grid(Array(SymbolCatalog.search("", kind: .emoji).prefix(12)), y: bottom + 60) + 10
            }
        } else {
            let kind: SymbolKind = selectedTab == 1 ? .emoji : selectedTab == 3 ? .kaomoji : .symbol
            label(tabNames[selectedTab], y: 0)
            height = grid(SymbolCatalog.search("", kind: kind), y: 32, columns: kind == .kaomoji ? 3 : 6) + 10
        }
        document.frame = NSRect(x: 0, y: 0, width: 328, height: max(250, height))
        itemButtons.first?.selectionHighlighted = true
    }
    @discardableResult private func mediaAction(_ title: String, x: CGFloat = 0, y: CGFloat, width: CGFloat = 104, enabled: Bool = true, action: @escaping () -> Void) -> CGFloat {
        let button = FluentButton(title: title)
        button.theme = theme
        let fittedWidth = min(max(width, button.intrinsicContentSize.width), max(1, 328 - x))
        button.frame = NSRect(x: x, y: y, width: fittedWidth, height: 30)
        button.isEnabled = enabled; button.onClick = action; document.addSubview(button)
        return fittedWidth
    }
    private func buildClipboard() -> CGFloat {
        label(L10n.clipboardTitle, y: 0, size: 16)
        mediaAction(L10n.clipboardClear, x: 218, y: 0, width: 110, enabled: !clipboard.entries.isEmpty || clipboard.storageError != nil) { [weak self] in
            guard let self else { return }
            do { try self.clipboard.clear(); self.mediaStatus = L10n.clipboardCleared }
            catch { self.mediaStatus = L10n.clipboardStorageError }
            self.reload()
        }
        mediaAction(clipboard.isRecording ? L10n.clipboardPause : L10n.clipboardStart, x: 132, y: 0, width: 82) {
            Preferences.shared.clipboardRecording = !Preferences.shared.clipboardRecording
        }
        let status = mediaStatus.isEmpty ? clipboard.storageError ?? "" : mediaStatus
        if !status.isEmpty { label(status, y: 36, size: 12) }
        var cardY: CGFloat = status.isEmpty ? 46 : 98
        if clipboard.entries.isEmpty { label(clipboard.isRecording ? L10n.clipboardEmpty : L10n.clipboardDisabled, y: 128, size: 13) }
        let entries = clipboard.entries.sorted { $0.isPinned == $1.isPinned ? $0.date > $1.date : $0.isPinned }
        for entry in entries {
            let card = ClipboardCard(entry); card.theme = theme; card.toolTip = L10n.clipboardPasteHint
            let height: CGFloat = entry.kind == .image ? 98 : entry.kind == .files ? 64 : 80
            card.frame = NSRect(x: 0, y: cardY, width: 328, height: height)
            cardY += height + 8
            card.onCopy = { [weak self] in
                guard let self else { return }
                self.mediaStatus = self.clipboard.copy(entry) ? L10n.clipboardCopied : L10n.clipboardCopyError
                self.reload(resetScroll: false)
            }
            card.onSelect = { [weak self, weak card] in
                if entry.kind == .text || entry.kind == .link { self?.onInsert?(entry.text) }
                else { card?.onCopy?() }
            }
            card.onPin = { [weak self] in
                guard let self else { return }
                do { try self.clipboard.setPinned(entry.id, !entry.isPinned); self.mediaStatus = "" }
                catch { self.mediaStatus = L10n.clipboardStorageError }
                self.reload(resetScroll: false)
            }
            card.onRemove = { [weak self] in
                guard let self else { return }
                do { try self.clipboard.remove(entry.id); self.mediaStatus = "" }
                catch { self.mediaStatus = L10n.clipboardStorageError }
                self.reload(resetScroll: false)
            }
            document.addSubview(card)
        }
        return max(250, cardY + 12)
    }
    private func buildGIFs(query: String) -> CGFloat {
        label("GIF", y: 0, size: 16)
        mediaAction(L10n.gifAdd, x: 222, y: 0) { [weak self] in self?.addGIFs() }
        label(mediaStatus.isEmpty ? L10n.gifPasteHint : mediaStatus, y: 42, size: 12)
        let entries = gifs.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        if entries.isEmpty { label(query.isEmpty ? L10n.gifEmpty : L10n.gifNoResults, y: 88, size: 13) }
        for (index, entry) in entries.enumerated() {
            let x = CGFloat(index % 3) * 110, y = 82 + CGFloat(index / 3) * 104
            let button = GIFPreviewButton(url: gifs.url(for: entry), name: entry.name); button.theme = theme
            button.frame = NSRect(x: x, y: y, width: 100, height: 68)
            button.invoke = { [weak self] in
                guard let self else { return }
                do { try self.gifs.copy(entry); self.mediaStatus = L10n.gifCopied }
                catch { self.mediaStatus = error.localizedDescription }
                self.reload()
            }
            document.addSubview(button)
            let name = NSTextField(labelWithString: entry.name)
            name.font = IMEFont.font(ofSize: 11); name.textColor = theme.textSecondary
            name.lineBreakMode = .byTruncatingTail; name.frame = NSRect(x: x, y: y + 72, width: 77, height: 18)
            document.addSubview(name)
            let remove = makeChromeButton(.close, label: L10n.gifRemoveAccessibility(entry.name))
            remove.theme = theme; remove.frame = NSRect(x: x + 80, y: y + 70, width: 20, height: 20)
            remove.onClick = { [weak self] in
                guard let self else { return }
                do { try self.gifs.remove(entry); self.mediaStatus = "" } catch { self.mediaStatus = error.localizedDescription }
                self.reload()
            }
            document.addSubview(remove)
        }
        return max(250, 82 + ceil(CGFloat(entries.count) / 3) * 104)
    }
    private func addGIFs() {
        guard let window, !isChoosingGIF else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.gif]; picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false; picker.prompt = L10n.commonAdd; picker.message = L10n.gifPickerTitle
        isChoosingGIF = true
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            self.isChoosingGIF = false
            if result == .OK {
                var added = 0; var errors: [String] = []
                for url in picker.urls {
                    do { try self.gifs.add(url); added += 1 } catch { errors.append(error.localizedDescription) }
                }
                self.mediaStatus = errors.first ?? L10n.gifAdded(added)
                self.reload()
            }
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(self.searchField)
        }
    }
    deinit { if let clipboardObserver { NotificationCenter.default.removeObserver(clipboardObserver) } }

}

/// Raw field editor avoids recursively invoking our own IMK input controller in search.
private final class SymbolSearchEditor: NSTextView {
    var onCommand: ((UInt16) -> Bool)?
    override var inputContext: NSTextInputContext? { nil }
    override func keyDown(with event: NSEvent) {
        if onCommand?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}

final class EmojiPanel: NSPanel, NSWindowDelegate {
    let paletteView = EmojiPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
    private let shadowPanel = CandidateShadowPanel()
    private let searchEditor = SymbolSearchEditor()
    private var activationObserver: NSObjectProtocol?
    private var insertAction: ((String) -> Void)?
    private var dismissAction: (() -> Void)?
    private var presenting = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = L10n.symbolsTitle
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isFloatingPanel = true
        animationBehavior = .none
        hidesOnDeactivate = false; becomesKeyOnlyIfNeeded = true
        level = IMEPopupLevel.emoji
        shadowPanel.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = paletteView; delegate = self
        searchEditor.isFieldEditor = true
        searchEditor.onCommand = { [weak self] key in
            guard let self else { return false }
            switch key {
            case 53: self.dismiss(); return true
            case 36, 76: self.paletteView.insertSelection(); return true
            case 125: self.paletteView.moveRow(backward: false); return true
            case 126: self.paletteView.moveRow(backward: true); return true
            default: return false
            }
        }
        paletteView.onClose = { [weak self] in self?.dismiss() }
        paletteView.onInsert = { [weak self] text in
            guard let self else { return }
            let insert = self.insertAction
            self.dismiss()
            insert?(text)
        }
    }
    func present(near anchor: NSRect, onInsert: @escaping (String) -> Void, onDismiss: (() -> Void)? = nil) {
        dismiss()
        insertAction = onInsert; dismissAction = onDismiss
        paletteView.prepare()
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        if let screen { setFrame(PanelPlacement.frame(size: NSSize(width: 360, height: 400), caret: anchor, screen: screen.visibleFrame), display: true) }
        let originalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != originalPID, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.dismiss()
        }
        shadowPanel.shadowView.theme = IMEThemeObservation.current
        shadowPanel.setFrame(CandidateChrome.shadowFrame(around: frame, flipped: false), display: true)
        shadowPanel.orderFrontRegardless()
        presenting = true; makeKeyAndOrderFront(nil); makeFirstResponder(paletteView.searchField); presenting = false
        if !(childWindows?.contains(where: { $0 === shadowPanel }) ?? false) { addChildWindow(shadowPanel, ordered: .below) }
    }
    func dismiss() {
        let completion = dismissAction
        dismissAction = nil; insertAction = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        orderOut(nil); completion?()
    }
    override func orderOut(_ sender: Any?) { shadowPanel.orderOut(sender); super.orderOut(sender) }
    func windowDidResignKey(_ notification: Notification) { if isVisible && !presenting && !paletteView.isChoosingGIF { dismiss() } }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if let field = client as? NSTextField, field === paletteView.searchField { return searchEditor }
        return nil
    }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    deinit { if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) } }
}
