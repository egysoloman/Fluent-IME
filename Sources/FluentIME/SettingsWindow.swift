import AppKit
import FluentKit
import FluentIMECore

private final class SettingsRoot: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override func mouseDown(with event: NSEvent) {
        // Empty page/chrome clicks reach this responder. End native editing through
        // the window so composition and validation retain their normal lifecycle.
        if window?.makeFirstResponder(self) != true { super.mouseDown(with: event) }
    }
    override func layout() { super.layout(); onLayout?() }
}

private final class SettingsScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 3, y: knob.minY, width: 2, height: knob.height), xRadius: 1, yRadius: 1).fill()
    }
}

private final class SettingsScrollView: NSScrollView {
    var onViewportSizeChange: (() -> Void)?
    private var lastViewportSize = NSSize(width: -1, height: -1)
    override func tile() {
        super.tile()
        let size = contentView.bounds.size
        guard size != lastViewportSize else { return }
        lastViewportSize = size
        onViewportSizeChange?()
    }
}

private final class SettingsBreadcrumbButton: NSButton {
    var ink = NSColor.labelColor
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? IMEFont.font(ofSize: 28), .foregroundColor: ink]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(at: NSPoint(x: 2, y: (bounds.height - height) / 2), withAttributes: attributes)
    }
}

private final class SettingsBreadcrumbSeparator: NSView {
    var ink = NSColor.secondaryLabelColor
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ink.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: bounds.midX - 2.5, y: bounds.midY - 5))
        path.line(to: NSPoint(x: bounds.midX + 2.5, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.midX - 2.5, y: bounds.midY + 5)); path.stroke()
    }
}

private final class SettingsNavigationButton: NSButton {
    static let textInset: CGFloat = 44
    var invoke: (() -> Void)?
    var detail = ""
    var isCurrent = false
    var theme = Preferences.shared.theme
    private var hovered = false
    private var iconSize: CGFloat = 22
    override var isFlipped: Bool { true }
    init(title: String, detail: String = "", glyph: SettingsGlyph, selected: Bool = false, theme: FluentTheme) {
        super.init(frame: .zero)
        self.title = title; self.detail = detail; self.isCurrent = selected; self.theme = theme
        iconSize = glyph == .updates ? 28 : 22
        image = glyph.image(color: theme.textPrimary, pointSize: iconSize)
        isBordered = false; target = self; action = #selector(clicked)
        setAccessibilityLabel(detail.isEmpty ? title : L10n.navigationItem(title, detail))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func clicked() { invoke?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isCurrent || hovered {
            theme.subtleFillSecondary.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        if isCurrent {
            theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: (bounds.height - 16) / 2, width: 3, height: 16), xRadius: 1.5, yRadius: 1.5).fill()
        }
        let hasDetail = !detail.isEmpty
        if let image {
            FluentIconSource.image(image).draw(in: NSRect(x: 21 - iconSize / 2, y: (hasDetail ? 23 : 19) - iconSize / 2, width: iconSize, height: iconSize), color: theme.textPrimary)
        }
        (title as NSString).draw(at: NSPoint(x: Self.textInset, y: hasDetail ? 7 : 8), withAttributes: [.font: IMEFont.font(ofSize: 14), .foregroundColor: theme.textPrimary])
        if hasDetail {
            (detail as NSString).draw(at: NSPoint(x: Self.textInset, y: 28), withAttributes: [.font: IMEFont.font(ofSize: 12), .foregroundColor: theme.textSecondary])
        }
        if window?.firstResponder === self {
            theme.accent.setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke()
        }
    }
}

final class PreviewTextView: NSTextView {
    var input: InputSession?
    override var inputContext: NSTextInputContext? { nil }
    override func keyDown(with event: NSEvent) { if input?.handle(event) != true { super.keyDown(with: event) } }
    override func flagsChanged(with event: NSEvent) { if input?.handle(event) != true { super.flagsChanged(with: event) } }
    override func resignFirstResponder() -> Bool { input?.finish(); return super.resignFirstResponder() }
    override func mouseDown(with event: NSEvent) { input?.finish(); input?.resetContext(); super.mouseDown(with: event) }
}

private enum SettingsPage: String, CaseIterable {
    case home, language, modes, general, keys, appearance, dictionary, models, advanced, preview, fonts, clipboard, updates, updateHistory
    var title: String {
        switch self {
        case .home: return L10n.settingsInputMethod
        case .language: return L10n.settingsLanguagesTitle
        case .modes: return L10n.settingsModesTitle
        case .general: return L10n.settingsGeneralTitle
        case .keys: return L10n.settingsKeysTitle
        case .appearance: return L10n.settingsAppearanceTitle
        case .dictionary: return L10n.settingsDictionaryTitle
        case .models: return L10n.modelsTitle
        case .advanced: return L10n.settingsAdvancedTitle
        case .preview: return L10n.previewTitle
        case .fonts: return L10n.fontTitle
        case .updates: return L10n.updatePageTitle
        case .updateHistory: return L10n.updateHistoryTitle
        case .clipboard: return L10n.clipboardTitle
        }
    }
    var detail: String {
        switch self {
        case .home: return L10n.settingsHomeDetail
        case .language: return L10n.settingsLanguageDetail
        case .modes: return L10n.settingsModesDetail
        case .general: return L10n.settingsGeneralDetail
        case .keys: return L10n.settingsKeysDetail
        case .appearance: return L10n.settingsAppearanceDetail
        case .dictionary: return L10n.settingsDictionaryDetail
        case .models: return L10n.modelsDetail
        case .advanced: return L10n.settingsAdvancedDetail
        case .preview: return L10n.previewTitle
        case .fonts: return L10n.fontHint
        case .updates: return L10n.updatePageDetail
        case .updateHistory: return L10n.updateHistoryHint
        case .clipboard: return L10n.clipboardDetail
        }
    }
    var icon: SettingsGlyph {
        switch self {
        case .home, .language, .modes, .general: return .general
        case .keys, .preview: return .keyboard
        case .appearance, .fonts: return .appearance
        case .dictionary, .models: return .dictionary
        case .clipboard: return .clipboard
        case .advanced: return .advanced
        case .updates: return .updates
        case .updateHistory: return .updateHistory
        }
    }
    static let categories: [SettingsPage] = [.modes, .keys, .appearance, .models, .clipboard, .updates, .advanced]
}

/// Compact native settings: retain the reference content geometry without the Windows sidebar.
/// All pages contain native AppKit/FluentKit controls and retain their real input state.
final class SettingsWindowController: NSWindowController, NSSearchFieldDelegate {
    private let engine: RimeEngine
    private let input: InputSession
    private let sampleInput: InputSession
    private let root = SettingsRoot()
    private let material = FluentMaterialView(material: .mica)
    private let breadcrumbs = IMEFlippedView()
    private let scroll = SettingsScrollView()
    private let pageDocument = IMEFlippedView()
    private let pageContent = IMEFlippedView()
    private let search = FluentSearchTextField(placeholder: L10n.settingsSearchPlaceholder)
    private let pageMotion = IMEPageMotion()
    private var titleBar: FluentViewHost<FluentTitleBar>?
    private var titleBarWidth: CGFloat = 0
    private var titleBarBackVisible = false
    private let titleBarMotion = IMETitleBarMotion()
    private let editor = PreviewTextView(frame: .zero)
    private let candidates = CandidateView(frame: .zero)
    private let candidateShadow = CandidateShadowView(frame: .zero)
    private let emojiPanel = EmojiPanel()
    private let modeIndicator = InputModePanel()
    private var indicatedMode: InputMode?
    private var theme = IMEThemeObservation.current
    private var page: SettingsPage = .home
    private var observer: NSObjectProtocol?
    private var appearanceObserver: IMEThemeObservation?
    private var sample: Composition { sampleInput.composition }
    private var fontSignature = FontPreferences.signature
    private var clipboardStatus = ""
    private var clipboardObserver: NSObjectProtocol?
    private var clipboardStamp = ""
    private func refreshClipboardPage() {
        guard page == .clipboard else { return }
        buildPage(); layout()
    }
    private var modelStatus = ""
    private weak var neuralStatusLabel: NSTextField?
    private var neuralObserver: NSObjectProtocol?
    private func neuralStatusText() -> String {
        guard let ranker = NeuralRuntime.shared.ranker else { return L10n.dictionaryModelMissing }
        let state = ranker.diagnostics
        if state.failed { return L10n.neuralUnavailable }
        if !state.ready { return L10n.neuralWaiting }
        return state.scored == 0 ? L10n.neuralReady : L10n.neuralScored(state.scored, String(format: "%.1f", state.milliseconds))
    }
    private var settingsLanguage = Preferences.shared.enabledInputModes[0]
    private var setupWindow: SetupWindowController?
    private var documentHeight: CGFloat = 500
    private var editorSurface: NSView?
    private var languageButton: FluentButton?
    private var previewExpanded: Bool?
    private var previewMotionTarget: NSRect?
    private var previewMotionTimer: Timer?
    private var pageWidthUpdates: [(CGFloat) -> Void] = []
    private var pageAppearanceUpdates: [(FluentTheme) -> Void] = []
    private var breadcrumbAppearanceUpdates: [(FluentTheme) -> Void] = []

    init(engine: RimeEngine) throws {
        self.engine = engine
        input = try InputSession(engine: engine, options: { Preferences.shared.inputOptions }, ranker: NeuralRuntime.shared.ranker, languageOptions: { Preferences.shared.inputOptions(for: $0) })
        sampleInput = try InputSession(engine: engine, options: {
            var value = Preferences.shared.inputOptions; value.learning = false; value.neuralRanking = false; return value
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 837),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.settingsWindowTitle
        window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 680)
        window.setFrame(NSRect(x: 0, y: 0, width: 640, height: 837), display: false)
        super.init(window: window)
        neuralObserver = NotificationCenter.default.addObserver(forName: CoreMLCandidateRanker.statusChanged, object: nil, queue: .main) { [weak self] _ in self?.neuralStatusLabel?.stringValue = self?.neuralStatusText() ?? "" }
        clipboardObserver = NotificationCenter.default.addObserver(forName: ClipboardHistory.changed, object: ClipboardHistory.shared, queue: .main) { [weak self] _ in
            guard let self else { return }
            let history = ClipboardHistory.shared
            let stamp = "\(String(describing: history.storageActivity))|\(history.storageEncrypted)|\(history.storageError ?? "")"
            guard self.clipboardStamp != stamp else { return }
            self.clipboardStamp = stamp; self.refreshClipboardPage()
        }
        root.fluentSetLocalization(locale: L10n.locale)
        window.contentView = root
        for view in [material, breadcrumbs, scroll] { root.addSubview(view) }
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.verticalScroller = SettingsScroller(); scroll.documentView = pageDocument
        pageDocument.addSubview(pageContent)
        scroll.onViewportSizeChange = { [weak self] in self?.root.needsLayout = true }
        search.delegate = self; search.setAccessibilityLabel(L10n.settingsSearchAccessibility)
        search.onCancel = { [weak self] in guard let self else { return }; self.navigate(.home) }
        editor.font = IMEFont.font(ofSize: 16); editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 4, height: 8)
        editor.setAccessibilityLabel(L10n.previewEditorAccessibility); editor.input = input
        input.onCommit = { [weak self] text in self?.editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        input.onExpansionChange = { Preferences.shared.expandedCandidates = $0 }
        input.onUpdate = { [weak self] composition in
            guard let self else { return }
            if composition.isComposing || self.editor.hasMarkedText() {
                self.editor.setMarkedText(composition.preedit,
                    selectedRange: NSRange(location: composition.cursorUTF16, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            self.refreshCandidates()
            if composition.isComposing { self.modeIndicator.dismiss() }
            if let old = self.indicatedMode, old != self.input.mode { self.showModeIndicator() }
            self.indicatedMode = self.input.mode
        }
        candidates.onSelect = { [weak self] index in
            guard let self else { return }
            if self.input.composition.isComposing { self.input.choose(index) }
            else if self.sample.candidates.indices.contains(index) {
                self.editor.insertText(self.sample.candidates[index].text, replacementRange: self.editor.selectedRange())
                Preferences.shared.expandedCandidates = false
            }
            self.window?.makeFirstResponder(self.editor)
        }
        candidates.onPage = { [weak self] backward in
            guard let self else { return }; (self.input.composition.isComposing ? self.input : self.sampleInput).page(backward: backward)
        }
        candidates.onEmoji = { [weak self] in self?.showEmoji() }
        candidates.onLayoutChange = { [weak self] in self?.refreshCandidates() }
        candidates.onLoadMore = { [weak self] in
            guard let self else { return }; (self.input.composition.isComposing ? self.input : self.sampleInput).loadMoreCandidates()
        }
        candidates.onViewportChanged = { [weak self] start, columns in self?.input.setCandidateViewport(start: start, columns: columns) }
        candidates.onInteraction = { [weak self] in self?.input.lockRanking() }
        for character in "she".utf8 { sampleInput.rime.process(key: Int32(character)) }
        sampleInput.onUpdate = { [weak self] _ in self?.refreshCandidates() }
        if let requested = ProcessInfo.processInfo.environment["FLUENTIME_RENDER_PAGE"], let initial = SettingsPage(rawValue: requested) { page = initial }
        root.onLayout = { [weak self] in self?.layout() }
        indicatedMode = input.mode
        applyTheme(); layout(); buildBreadcrumbs(); buildPage(); layout(); window.center()
        observer = NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in self?.preferencesChanged() }
        appearanceObserver = IMEThemeObservation { [weak self] in self?.appearanceChanged($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let clipboardObserver { NotificationCenter.default.removeObserver(clipboardObserver) }
        if let neuralObserver { NotificationCenter.default.removeObserver(neuralObserver) }
        previewMotionTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func layout() {
        let width = root.bounds.width, height = root.bounds.height
        material.frame = root.bounds
        if abs(width - titleBarWidth) > 0.5 { updateTitleBar() }
        titleBar?.frame = NSRect(x: 0, y: 0, width: width, height: 48)
        let breadcrumbWidthChanged = breadcrumbs.frame.width != width - 46
        breadcrumbs.frame = NSRect(x: 22, y: 68, width: width - 46, height: 44)
        if breadcrumbWidthChanged && !breadcrumbs.subviews.isEmpty { buildBreadcrumbs() }
        scroll.frame = NSRect(x: 0, y: 136, width: width, height: height - 136)
        let trailingInset: CGFloat = page == .preview ? max(20, CandidateChrome.sideMargin) : 20
        // Keep the leading gutter inside the viewport so outgoing page motion is not sliced at the text edge.
        pageDocument.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(documentHeight, scroll.contentSize.height))
        pageContent.frame = NSRect(x: 24, y: 0, width: max(1, scroll.contentSize.width - 24 - trailingInset), height: pageDocument.bounds.height)
        pageWidthUpdates.forEach { $0(pageContent.bounds.width) }
        if page == .preview {
            let available = min(860, pageContent.bounds.width - 30)
            let widthChanged = editorSurface?.frame.width != available
            editorSurface?.frame.size.width = available
            editor.frame.size.width = available - 24
            if widthChanged { refreshCandidates() }
        }
    }
    private func updateTitleBar() {
        let search = self.search
        let showBack = page != .home
        let visibilityChanged = showBack != titleBarBackVisible
        titleBarBackVisible = showBack
        let snapshot = visibilityChanged ? titleBar.flatMap { titleBarMotion.capture($0) } : nil
        titleBarWidth = root.bounds.width
        let definition = FluentTitleBar(
            title: L10n.settingsTitle, heightMode: .expanded, backgroundStyle: .transparent,
            windowControlsStyle: .windows,
            isBackButtonVisible: showBack, isBackButtonEnabled: showBack,
            onBack: { [weak self] in self?.goBack() },
            leftHeader: { FluentEmptyView() },
            content: {
                FluentNativeView(search)
                    .frame(width: min(480, max(240, titleBarWidth - 420)), height: 32)
                    .titleBarPrimary()
            },
            rightHeader: { FluentEmptyView() }
        )
        let context = FluentRenderContext(theme: theme, locale: L10n.locale)
        if let titleBar {
            titleBar.update(definition, context: context)
        } else {
            let host = FluentViewHost(definition, context: context)
            host.translatesAutoresizingMaskIntoConstraints = true
            titleBar = host; root.addSubview(host)
        }
        if let snapshot, let titleBar {
            titleBar.frame = NSRect(x: 0, y: 0, width: titleBarWidth, height: 48)
            titleBar.layoutSubtreeIfNeeded()
            titleBarMotion.play(snapshot, in: titleBar, showingBack: showBack)
        }
    }
    private func applyTheme() {
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        material.fluentTheme = theme
        material.isMaterialEnabled = false
        material.fallbackColor = theme.isDark ? NSColor(srgbRed: 0.125, green: 0.125, blue: 0.125, alpha: 1) : NSColor(srgbRed: 240/255, green: 243/255, blue: 249/255, alpha: 1)
        search.theme = theme
        updateTitleBar()
        editor.textColor = theme.textPrimary; editor.insertionPointColor = theme.textPrimary
    }
    private func preferencesChanged() {
        if isLanguagePage, !Preferences.shared.enabledInputModes.contains(settingsLanguage) { navigate(.home); return }
        if fontSignature != FontPreferences.signature {
            fontSignature = FontPreferences.signature
            theme = IMEThemeObservation.current
            root.fluentSetLocalization(locale: L10n.locale)
            window?.title = L10n.settingsWindowTitle
            search.placeholderString = L10n.settingsSearchPlaceholder
            editor.font = IMEFont.font(ofSize: 16)
            applyTheme(); buildBreadcrumbs(); buildPage(); layout()
        }
        input.applyOptions()
        sampleInput.applyOptions()
        if !sampleInput.composition.isComposing {
            for character in "she".utf8 { sampleInput.rime.process(key: Int32(character)) }
        }
        refreshCandidates()
        if !Preferences.shared.showInputModeIndicator { modeIndicator.dismiss() }
    }
    private func appearanceChanged(_ updated: FluentTheme) {
        guard updated != theme else { return }
        pageMotion.cancel(); titleBarMotion.cancel()
        theme = updated; applyTheme()
        breadcrumbAppearanceUpdates.forEach { $0(updated) }
        pageAppearanceUpdates.forEach { $0(updated) }
    }
    private func navigate(_ destination: SettingsPage) {
        if [.language, .general, .dictionary].contains(destination), !Preferences.shared.enabledInputModes.contains(settingsLanguage) { navigate(.home); return }
        if search.currentEditor() != nil || window?.firstResponder === search {
            guard window?.makeFirstResponder(root) == true else { return }
        }
        let oldPage = page
        let snapshot = oldPage != destination ? pageMotion.capture(scroll.contentView) : nil
        input.finish(); emojiPanel.dismiss(); modeIndicator.dismiss(); Preferences.shared.expandedCandidates = false; search.stringValue = ""; page = destination
        buildBreadcrumbs(); buildPage(); layout(); scroll.contentView.scroll(to: .zero)
        root.layoutSubtreeIfNeeded()
        pageMotion.play(snapshot, in: scroll.contentView, content: pageContent, backward: destination == .home || (oldPage == .updateHistory && destination == .updates), navigation: true)
        if destination == .preview { window?.makeFirstResponder(editor) }
    }
    private func fitPageWidth(_ view: NSView) {
        let maximumWidth = view.frame.width
        let update: (CGFloat) -> Void = { [weak view] width in
            guard let view else { return }
            view.frame.size.width = min(maximumWidth, max(1, width - view.frame.minX))
        }
        pageWidthUpdates.append(update)
        update(pageContent.bounds.width)
    }
    private func label(_ text: String, x: CGFloat = 0, y: CGFloat, size: CGFloat = 14, secondary: Bool = false, width: CGFloat = 540, parent: NSView? = nil) -> NSTextField {
        let label = FluentSelectableLabel(wrappingLabelWithString: text)
        label.theme = theme
        label.font = IMEFont.font(ofSize: size, weight: .regular); label.textColor = secondary ? theme.textSecondary : theme.textPrimary
        label.frame = NSRect(x: x, y: y, width: width, height: size + 12)
        pageAppearanceUpdates.append { [weak label] theme in label?.textColor = secondary ? theme.textSecondary : theme.textPrimary; label?.theme = theme }
        (parent ?? pageContent).addSubview(label)
        if parent == nil { fitPageWidth(label) }
        return label
    }
    private func action(_ title: String, x: CGFloat = 0, y: CGFloat, width: CGFloat = 180, role: FluentButtonRole = .standard, parent: NSView? = nil, invoke: @escaping () -> Void) -> FluentButton {
        let button = FluentButton(title: title, role: role); button.theme = theme; button.onClick = invoke
        button.frame = NSRect(x: x, y: y, width: max(width, button.intrinsicContentSize.width), height: 32)
        pageAppearanceUpdates.append { [weak button] theme in button?.theme = theme }
        (parent ?? pageContent).addSubview(button); return button
    }
    private func buildBreadcrumbs() {
        breadcrumbAppearanceUpdates.removeAll()
        breadcrumbs.subviews.forEach { $0.removeFromSuperview() }
        let parts = page == .home ? [L10n.settingsInputMethod] : isLanguagePage ? ([L10n.settingsInputMethod, settingsLanguage.title] + (page == .language ? [] : [page.title])) : page == .fonts ? [L10n.settingsInputMethod, L10n.settingsAppearanceTitle, page.title] : page == .updateHistory ? [L10n.settingsInputMethod, L10n.updatePageTitle, page.title] : [L10n.settingsInputMethod, page.title]
        // Longer translations share the same breadcrumb row without clipping.
        var pointSize: CGFloat = 28
        func totalWidth() -> CGFloat {
            parts.enumerated().reduce(CGFloat(max(0, parts.count - 1) * 42)) { width, part in
                width + ceil((part.element as NSString).size(withAttributes: [.font: IMEFont.font(ofSize: pointSize, weight: part.offset == parts.count - 1 ? .medium : .regular)]).width) + 4
            }
        }
        while pointSize > 18 && totalWidth() > breadcrumbs.bounds.width { pointSize -= 0.5 }
        var x: CGFloat = 0
        for (index, text) in parts.enumerated() {
            let font = IMEFont.font(ofSize: pointSize, weight: index == parts.count - 1 ? .medium : .regular)
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4
            let button = SettingsBreadcrumbButton(title: text, target: self, action: #selector(breadcrumbClicked(_:)))
            button.tag = index; button.isEnabled = index < parts.count - 1; button.isBordered = false; button.font = font; button.ink = index == parts.count - 1 ? theme.textPrimary : theme.textSecondary
            button.frame = NSRect(x: x, y: 0, width: width, height: 44); breadcrumbs.addSubview(button); x += width
            breadcrumbAppearanceUpdates.append { [weak button] theme in
                button?.ink = index == parts.count - 1 ? theme.textPrimary : theme.textSecondary
                button?.needsDisplay = true
            }
            if index < parts.count - 1 {
                let separator = SettingsBreadcrumbSeparator(frame: NSRect(x: x, y: 0, width: 42, height: 44))
                separator.ink = theme.textSecondary; breadcrumbs.addSubview(separator); x += 42
                breadcrumbAppearanceUpdates.append { [weak separator] theme in separator?.ink = theme.textSecondary; separator?.needsDisplay = true }
            }
        }
        updateTitleBar()
    }
    @objc private func breadcrumbClicked(_ sender: NSButton) { navigate(sender.tag == 1 ? (isLanguagePage ? .language : page == .fonts ? .appearance : page == .updateHistory ? .updates : .home) : .home) }

    private var isLanguagePage: Bool { [.language, .general, .dictionary].contains(page) }
    private func goBack() { navigate(page == .updateHistory ? .updates : page == .fonts ? .appearance : isLanguagePage && page != .language ? .language : .home) }
    private func navigationRow(_ title: String, detail: String, glyph: SettingsGlyph, y: CGFloat, invoke: @escaping () -> Void) {
        let button = SettingsNavigationButton(title: title, detail: detail, glyph: glyph, theme: theme)
        button.frame = NSRect(x: 0, y: y, width: 562, height: 58); button.invoke = invoke
        pageContent.addSubview(button); fitPageWidth(button)
        pageAppearanceUpdates.append { [weak button] theme in button?.theme = theme; button?.image = glyph.image(color: theme.textPrimary); button?.needsDisplay = true }
    }
    private func showSetup() {
        setupWindow = SetupWindowController(onComplete: { [weak self] in self?.showWindow(nil) })
        setupWindow?.showWindow(nil)
    }
    private func showUninstall() { MaintenanceDialogs.uninstall(in: root) }
    private func manageDictionary() { MaintenanceDialogs.dictionary(in: root) }
    private func toggle(_ title: String, y: CGFloat, value: Bool, enabled: Bool = true, changed: @escaping (Bool) -> Void) {
        _ = label(title, y: y)
        let control = FluentToggle(title: "", isOn: value)
        control.theme = theme; control.frame = NSRect(x: 0, y: y + 28, width: 40, height: 26)
        control.isEnabled = enabled; control.setAccessibilityElement(true); control.setAccessibilityRole(.checkBox); control.setAccessibilityLabel(title)
        pageContent.addSubview(control)
        pageAppearanceUpdates.append { [weak control] theme in control?.theme = theme }
        let state = label(value ? L10n.stateOn : L10n.stateOff, x: 52, y: y + 30, secondary: !enabled, width: 60)
        control.onValueChanged = { value in state.stringValue = value ? L10n.stateOn : L10n.stateOff; changed(value) }
    }
    private func choice(_ title: String, y: CGFloat, width: CGFloat = 180, options: [(id: String, title: String)], selected: String, changed: @escaping (String) -> Void) {
        _ = label(title, y: y)
        var value: String? = selected
        let binding = FluentBinding<String?>(get: { value }, set: { value = $0; if let selection = $0 { changed(selection) } })
        let titles = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.title) })
        let definition = FluentComboBox(options: options.map(\.id), selection: binding, title: { titles[$0] ?? $0 })
        let view = definition._makeView(in: FluentRenderContext(theme: theme, locale: L10n.locale))
        pageAppearanceUpdates.append { [weak view] theme in
            if let view { _ = definition._updateView(view, in: FluentRenderContext(theme: theme, locale: L10n.locale)) }
        }
        view.frame = NSRect(x: 0, y: y + 27, width: width, height: 32)
        view.setAccessibilityLabel(title); pageContent.addSubview(view)
    }
    private func buildPage() {
        previewMotionTimer?.invalidate(); previewMotionTimer = nil; previewExpanded = nil
        pageAppearanceUpdates.removeAll()
        pageWidthUpdates.removeAll()
        pageContent.subviews.forEach { $0.removeFromSuperview() }; editorSurface = nil; languageButton = nil; documentHeight = 500
        let p = Preferences.shared
        search.isEnabled = true
        let language = LanguagePreferences(settingsLanguage)
        switch page {
        case .home:
            let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var y: CGFloat = 0
            let modes = p.enabledInputModes.filter { query.isEmpty || ($0.title + L10n.settingsLanguageDetail).localizedCaseInsensitiveContains(query) }
            if !modes.isEmpty { _ = label(L10n.settingsLanguagesTitle, y: y, size: 18); y += 38 }
            for mode in modes {
                navigationRow(mode.title, detail: mode.isChinese ? L10n.settingsLanguageDetail : L10n.settingsEnglishDetail, glyph: .general, y: y) { [weak self] in
                    guard p.enabledInputModes.contains(mode) else { return }
                    self?.settingsLanguage = mode; self?.navigate(.language)
                }; y += 62
            }
            let items = SettingsPage.categories.filter { query.isEmpty || ($0.title + $0.detail).localizedCaseInsensitiveContains(query) }
            if !items.isEmpty { y += 20; _ = label(L10n.settingsSharedTitle, y: y, size: 18); y += 38 }
            for destination in items {
                navigationRow(destination.title, detail: destination.detail, glyph: destination.icon, y: y) { [weak self] in self?.navigate(destination) }; y += 62
            }
            if items.isEmpty && modes.isEmpty { _ = label(L10n.settingsNoResults, y: 12, secondary: true) }
            let preview = action(L10n.previewOpen, x: 36, y: y + 24) { [weak self] in self?.navigate(.preview) }
            preview.fluentStyle = FluentBorderlessButtonStyle()
            let alignPreview: (FluentTheme) -> Void = { [weak preview] _ in
                guard let preview else { return }
                let width = preview.intrinsicContentSize.width
                let text = (preview.title as NSString).size(withAttributes: [.font: preview.font ?? IMEFont.font(ofSize: 14)]).width
                preview.frame.size.width = width
                preview.frame.origin.x = 36 - (width - text) / 2
            }
            pageAppearanceUpdates.append(alignPreview); alignPreview(theme)
            documentHeight = y + 96
        case .language:
            let destinations: [SettingsPage] = settingsLanguage.isChinese ? [.general, .dictionary] : [.general]
            for (index, destination) in destinations.enumerated() {
                navigationRow(destination.title, detail: destination.detail, glyph: destination.icon, y: CGFloat(index * 62)) { [weak self] in self?.navigate(destination) }
            }
        case .modes:
            _ = label(L10n.generalEnabledModes, y: 0, size: 20)
            for (index, mode) in InputMode.allCases.enumerated() {
                let check = FluentCheckBox(title: mode.title, isChecked: p.enabledInputModes.contains(mode))
                check.theme = theme; check.frame = NSRect(x: 0, y: 52 + CGFloat(index * 44), width: 500, height: 30)
                check.isEnabled = p.enabledInputModes.count > 1 || !check.isChecked
                check.onValueChanged = { [weak self] selected in
                    p.enabledInputModes = selected ? p.enabledInputModes + [mode] : p.enabledInputModes.filter { $0 != mode }
                    self?.buildPage(); self?.layout()
                }
                pageContent.addSubview(check); fitPageWidth(check)
                pageAppearanceUpdates.append { [weak check] theme in check?.theme = theme }
            }
            choice(L10n.generalDefaultModeChoice, y: 224, width: 300, options: p.enabledInputModes.map { ($0.rawValue, $0.title) }, selected: p.defaultInputMode.rawValue) { if let mode = InputMode(rawValue: $0) { p.defaultInputMode = mode } }
        case .general:
            if settingsLanguage.isChinese {
                _ = label(L10n.generalPinyinTitle, y: 0, size: 20)
                choice(L10n.generalPinyinChoice, y: 48, options: [("pinyin", L10n.generalPinyinFull)], selected: "pinyin") { _ in }
                toggle(L10n.generalCorrection, y: 136, value: language.autoCorrection) { language.autoCorrection = $0 }
                toggle(L10n.generalAbbreviation, y: 210, value: language.abbreviation) { language.abbreviation = $0 }
            }
            let start: CGFloat = settingsLanguage.isChinese ? 302 : 0
            toggle(L10n.generalHalfWidth, y: start, value: language.halfWidth) { language.halfWidth = $0 }
            if settingsLanguage.isChinese {
                toggle(L10n.generalEnglishPunctuation, y: start + 74, value: language.englishPunctuation) { language.englishPunctuation = $0 }
                _ = label(L10n.generalFuzzy, y: start + 174, size: 20)
                for (index, rule) in FuzzyPinyinRule.allCases.enumerated() {
                    toggle(rule.title, y: start + 222 + CGFloat(index * 74), value: language.fuzzyPinyinMask & rule.rawValue != 0) { enabled in
                        language.fuzzyPinyinMask = enabled ? language.fuzzyPinyinMask | rule.rawValue : language.fuzzyPinyinMask & ~rule.rawValue
                    }
                }
                documentHeight = start + 850
            }
        case .keys:
            _ = label(L10n.keysModeSwitch, y: 0, size: 20)
            toggle(L10n.keysShift, y: 48, value: p.shiftSwitch) { p.shiftSwitch = $0 }
            _ = label(L10n.keysCapsLockHint, y: 110, size: 13, secondary: true)
            _ = label(L10n.keysCommitCodeHint, y: 138, size: 13, secondary: true)
            toggle(L10n.candidateExpand, y: 180, value: p.candidateExpansionEnabled) { p.candidateExpansionEnabled = $0 }
            _ = label(L10n.keysExpansionHint, y: 250, size: 13, secondary: true)
            _ = label(L10n.keysCandidates, y: 308, size: 20)
            toggle(L10n.keysKeepSelection, y: 352, value: p.keepCandidateSelectionOnPage) { p.keepCandidateSelectionOnPage = $0 }
            _ = label(L10n.keysKeepSelectionHint, y: 422, size: 13, secondary: true)
            let shortcuts = [("Space", L10n.keysConfirm), ("1–7", L10n.keysNumber), ("← / →、↑ / ↓", L10n.keysArrows), ("[ / ]、− / =、Page Up / Down", L10n.keysPaging), ("Enter", L10n.keysCommitRaw), ("Esc", L10n.keysCancel)]
            for (index, item) in shortcuts.enumerated() {
                let y = CGFloat(474 + index * 42)
                _ = label(item.0, y: y, width: 280); _ = label(item.1, x: 260, y: y, secondary: true, width: 300)
            }
            documentHeight = 762
        case .appearance:
            choice(L10n.appearanceInterfaceLanguage, y: 0, options: [("system", L10n.appearanceSystem), ("zh-Hans", L10n.languageSimplified), ("zh-Hant", L10n.languageTraditional), ("en", L10n.languageEnglish)], selected: p.interfaceLanguage) { p.interfaceLanguage = $0 }
            _ = label(L10n.appearanceInterfaceLanguageHint, y: 84, size: 13, secondary: true)
            navigationRow(L10n.fontTitle, detail: L10n.fontSharedDetail, glyph: .appearance, y: 120) { [weak self] in self?.navigate(.fonts) }
            _ = label(L10n.appearanceCandidates, y: 210, size: 20)
            _ = label(L10n.appearanceCandidateCount(7), y: 258, size: 13, secondary: true)
            toggle(L10n.appearancePopupAnimation, y: 294, value: p.candidatePopupAnimation) { p.candidatePopupAnimation = $0 }
            toggle(L10n.appearancePageAnimation, y: 372, value: p.candidatePageAnimation) { p.candidatePageAnimation = $0 }
            toggle(L10n.appearanceExpansionAnimation, y: 450, value: p.candidateExpansionAnimation) { p.candidateExpansionAnimation = $0 }
            _ = label(L10n.appearanceTheme, y: 560, size: 20)
            choice(L10n.appearanceThemeChoice, y: 608, options: [("system", L10n.appearanceSystem), ("light", L10n.appearanceLight), ("dark", L10n.appearanceDark)], selected: p.appearance) { p.appearance = $0 }
            _ = label(L10n.symbolsEmoji, y: 716, size: 20)
            _ = label(L10n.appearanceSymbolsHint, y: 762, size: 13, secondary: true)
            _ = action(L10n.previewTitle, y: 806) { [weak self] in self?.navigate(.preview) }
            toggle(L10n.appearanceAdvancedEffects, y: 886, value: p.advancedEffects) { p.advancedEffects = $0 }
            _ = label(L10n.appearanceAdvancedEffectsHint, y: 956, size: 13, secondary: true)
            toggle(L10n.modeIndicator, y: 1014, value: p.showInputModeIndicator) { p.showInputModeIndicator = $0 }
            _ = label(L10n.modeIndicatorHint, y: 1084, size: 13, secondary: true)
            documentHeight = 1150
        case .dictionary:
            _ = label(L10n.settingsDictionaryTitle, y: 0, size: 20)
            toggle(L10n.dictionaryLearning, y: 48, value: language.learning) { language.learning = $0 }
            _ = label(L10n.dictionaryLearningHint, y: 118, size: 13, secondary: true)
            _ = label(L10n.dictionaryLocal, y: 192, size: 20)
            _ = label(L10n.dictionaryWanxiang, y: 238, size: 14)
            _ = label(L10n.dictionaryContents, y: 270, size: 13, secondary: true)
            _ = action(L10n.dictionaryOpenFolder, y: 318, width: 200) { [weak self] in if let url = self?.engine.userDirectory { NSWorkspace.shared.open(url) } }
            _ = label(L10n.dictionaryLanguageModel, y: 390, size: 20)
            toggle(L10n.dictionaryGrammar, y: 438, value: language.wanxiangGrammar) { language.wanxiangGrammar = $0 }
            _ = label(L10n.dictionaryGrammarHint, y: 506, size: 13, secondary: true)
            toggle(L10n.dictionaryTransformer, y: 566, value: NeuralRuntime.shared.ranker != nil && language.neuralRanking, enabled: NeuralRuntime.shared.ranker != nil) { language.neuralRanking = $0 }
            _ = label(NeuralRuntime.shared.ranker == nil ? L10n.dictionaryModelMissing : L10n.dictionaryModelHint, y: 634, size: 13, secondary: true)
            _ = label(L10n.dictionaryContextHint, y: 666, size: 13, secondary: true)
            neuralStatusLabel = label(neuralStatusText(), y: 706, size: 13, secondary: true)
            _ = action(L10n.dictionaryManage, y: 758, width: 300) { [weak self] in self?.manageDictionary() }
            _ = action(L10n.modelsTitle, y: 814, width: 300) { [weak self] in self?.navigate(.models) }
            documentHeight = 894
        case .models:
            let selection = UserModels.library.selection
            for (index, grammar) in [true, false].enumerated() {
                let y = CGFloat(index * 290)
                _ = label(grammar ? L10n.modelsGrammarTitle : L10n.dictionaryTransformer, y: y, size: 20)
                let custom = grammar ? selection.grammar != nil : selection.transformer != nil
                let missing = !grammar && Bundle.main.resourceURL.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("Models/ChineseContextScorer.mlmodelc").path) } != false
                _ = label(custom ? L10n.modelsCustom : (missing ? L10n.dictionaryModelMissing : L10n.modelsBundled), y: y + 44, size: 13, secondary: true)
                paragraph(grammar ? L10n.modelsGrammarFormat : L10n.modelsTransformerFormat, y: y + 76, height: 64)
                _ = action(L10n.modelsDownload, y: y + 152, width: 170) { UserModels.download(grammar: grammar) }
                _ = action(L10n.modelsImport, x: 188, y: y + 152, width: 170) { [weak self] in
                    guard let self else { return }
                    UserModels.chooseImport(grammar: grammar, in: root) { [weak self] status in self?.modelStatus = status; self?.buildPage() }
                }
                let restore = action(L10n.modelsRestore, y: y + 204, width: 240) { [weak self] in
                    guard let self else { return }
                    UserModels.restore(grammar: grammar, in: root) { [weak self] status in self?.modelStatus = status; self?.buildPage() }
                }
                restore.isEnabled = custom
            }
            paragraph(modelStatus, y: 594, height: 60)
            documentHeight = 674
        case .advanced:
            let buttonWidth = [L10n.advancedOpenKeyboard, L10n.advancedLicenses, L10n.setupReopen, L10n.uninstallAction, L10n.updatePageTitle, L10n.maintenanceOpen].map { FluentButton(title: $0).intrinsicContentSize.width }.reduce(CGFloat(240), max)
            _ = label(L10n.advancedSystemInput, y: 0, size: 20)
            _ = label(L10n.advancedAddInputHint, y: 48)
            _ = action(L10n.advancedOpenKeyboard, y: 92, width: buttonWidth) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
            _ = label(L10n.advancedAbout, y: 192, size: 20)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.advancedDevelopment
            _ = label(L10n.advancedVersion(L10n.appName, version), y: 240)
            _ = label(L10n.advancedComponents(engine.version), y: 274, size: 13, secondary: true)
            _ = label(L10n.advancedOfflineHint, y: 306, size: 13, secondary: true)
            _ = action(L10n.advancedLicenses, y: 356, width: buttonWidth) {
                if let directory = Bundle.main.resourceURL?.appendingPathComponent("Licenses") { NSWorkspace.shared.open(directory) }
            }
            _ = action(L10n.setupReopen, y: 414, width: buttonWidth) { [weak self] in self?.showSetup() }
            _ = action(L10n.uninstallAction, y: 476, width: buttonWidth, role: .primary) { [weak self] in self?.showUninstall() }
            _ = action(L10n.updatePageTitle, y: 534, width: buttonWidth) { [weak self] in self?.navigate(.updates) }
            _ = action(L10n.maintenanceOpen, y: 592, width: buttonWidth) { [weak self] in
                Task { @MainActor in
                    do { try await MaintenanceClient.launch(.show) }
                    catch { if let root = self?.root { MaintenanceDialogs.showError(error, in: root) } }
                }
            }
            documentHeight = 666
        case .updates:
            let updates = UpdatePageView()
            updates.onOpenHistory = { [weak self] in self?.navigate(.updateHistory) }
            updates.frame = NSRect(x: 0, y: 0, width: 1000, height: updates.preferredHeight)
            pageContent.addSubview(updates); fitPageWidth(updates)
            documentHeight = updates.preferredHeight + 24
            updates.onHeightChange = { [weak self, weak updates] height in
                guard let self, self.page == .updates else { return }
                updates?.frame.size.height = height; self.documentHeight = height + 24; self.root.needsLayout = true
            }
        case .updateHistory:
            let history = UpdateHistoryPageView()
            history.frame = NSRect(x: 0, y: 0, width: 1000, height: history.preferredHeight)
            pageContent.addSubview(history); fitPageWidth(history)
            documentHeight = history.preferredHeight + 24
            history.onHeightChange = { [weak self, weak history] height in
                guard let self, self.page == .updateHistory else { return }
                history?.frame.size.height = height; self.documentHeight = height + 24; self.root.needsLayout = true
            }
        case .fonts:
            buildFonts()
            documentHeight = 600
        case .clipboard:
            let history = ClipboardHistory.shared
            _ = label(L10n.clipboardTitle, y: 0, size: 20)
            toggle(L10n.clipboardRecording, y: 54, value: p.clipboardRecording) { p.clipboardRecording = $0 }
            choice(L10n.clipboardRetention, y: 142, width: 300, options: retentionChoices, selected: String(p.clipboardRetention)) { p.clipboardRetention = Int($0) ?? 1800 }
            paragraph(L10n.clipboardPinnedHint, y: 228, height: 54)
            toggle(L10n.clipboardEncryption, y: 302, value: history.storageEncrypted, enabled: !history.isStorageBusy) { [weak self] enabled in
                self?.clipboardStatus = ""
                history.setEncryption(enabled) { [weak self] result in
                    if case .failure(let error) = result { self?.clipboardStatus = error.localizedDescription }
                    self?.refreshClipboardPage()
                }
            }
            paragraph(L10n.clipboardEncryptionHint, y: 374, height: 70)
            paragraph(L10n.clipboardPrivacyHint, y: 466, height: 52)
            paragraph(L10n.clipboardClearHint, y: 538, height: 58)
            let clear = action(L10n.clipboardClear, y: 618) { [weak self] in
                self?.clipboardStatus = ""
                history.clear { [weak self] result in
                    switch result {
                    case .success: self?.clipboardStatus = L10n.clipboardCleared
                    case .failure(let error): self?.clipboardStatus = error.localizedDescription
                    }
                    self?.refreshClipboardPage()
                }
            }
            clear.isEnabled = !history.isStorageBusy
            let status: String
            switch history.storageActivity {
            case .loading: status = L10n.clipboardLoading
            case .saving: status = L10n.clipboardSaving
            case .clearing: status = L10n.clipboardClearing
            case nil: status = clipboardStatus.isEmpty ? history.storageError ?? "" : clipboardStatus
            }
            paragraph(status, y: 666, height: 58)
            documentHeight = 740
        case .preview:
            _ = label(L10n.previewTitle, y: 0, size: 20)
            let surface = IMEFlippedView(frame: NSRect(x: 0, y: 48, width: 850, height: 88))
            surface.wantsLayer = true; surface.layer?.cornerRadius = 4; surface.layer?.backgroundColor = theme.controlFill.cgColor
            surface.layer?.borderWidth = 0.5; surface.layer?.borderColor = theme.controlStroke.cgColor
            pageAppearanceUpdates.append { [weak surface] theme in
                surface?.layer?.backgroundColor = theme.controlFill.cgColor; surface?.layer?.borderColor = theme.controlStroke.cgColor
            }
            pageContent.addSubview(surface); editorSurface = surface
            editor.frame = NSRect(x: 12, y: 10, width: 826, height: 68); surface.addSubview(editor)
            pageContent.addSubview(candidateShadow); pageContent.addSubview(candidates); refreshCandidates()
            let language = action("", y: 232, width: 180) { [weak self] in
                self?.input.toggleLanguage()
                self?.window?.makeFirstResponder(self?.editor)
            }
            language.refusesFirstResponder = true
            languageButton = language; refreshCandidates()
        }
    }
    private var retentionChoices: [(id: String, title: String)] {
        [("0", L10n.clipboardSession), ("900", L10n.clipboardMinutes15), ("1800", L10n.clipboardMinutes30), ("3600", L10n.clipboardHour1), ("86400", L10n.clipboardDay1), ("604800", L10n.clipboardDays7)]
    }
    private func paragraph(_ text: String, y: CGFloat, height: CGFloat) {
        let field = label(text, y: y, size: 13, secondary: true)
        field.frame.size.height = height
    }
    private func buildFonts() {
        paragraph(L10n.fontHint, y: 0, height: 60)
        for (index, mode) in InputMode.allCases.enumerated() {
            let y = CGFloat(80 + index * 160)
            choice(mode.title, y: y, width: 380, options: FontPreferences.choices, selected: FontPreferences.selected(mode)) { [weak self] value in
                FontPreferences.set(value, for: mode); self?.buildPage(); self?.layout()
            }
            let sample = mode == .simplifiedChinese ? L10n.fontSampleSimplified : mode == .traditionalChinese ? L10n.fontSampleTraditional : L10n.fontSampleEnglish
            let preview = label(sample, y: y + 78, size: 19)
            preview.frame.size.height = 46; preview.font = FontPreferences.font(size: 19, weight: .regular, language: mode)
        }
    }
    private func refreshCandidates() {
        guard page == .preview else { return }
        languageButton?.title = L10n.modeSwitchTo(input.nextMode.title)
        languageButton?.setAccessibilityLabel(L10n.modeSwitchTo(input.nextMode.title))
        candidates.isHidden = !input.isChinese
        candidateShadow.isHidden = candidates.isHidden
        candidates.language = input.mode
        candidates.update(input.composition.isComposing ? input.composition : sample, maxWidth: max(300, min(860, pageContent.bounds.width)))
        candidateShadow.theme = theme
        let target = NSRect(origin: NSPoint(x: 0, y: 141), size: candidates.preferredSize)
        let expanded = Preferences.shared.expandedCandidates
        let animate = previewExpanded != nil && previewExpanded != expanded && !candidates.isHidden
            && Preferences.shared.candidateExpansionAnimation && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        previewExpanded = expanded
        if previewMotionTimer != nil && previewMotionTarget == target { return }
        previewMotionTarget = target
        previewMotionTimer?.invalidate(); previewMotionTimer = nil
        guard animate, candidates.frame != target else { applyPreviewFrame(target); return }
        let initial = candidates.frame, start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.16)
            let progress = 1 - pow(1 - t, 3)
            self.applyPreviewFrame(NSRect(origin: target.origin, size: NSSize(
                width: initial.width + (target.width - initial.width) * progress,
                height: initial.height + (target.height - initial.height) * progress)))
            if t >= 1 { self.previewMotionTimer?.invalidate(); self.previewMotionTimer = nil }
        }
        previewMotionTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func applyPreviewFrame(_ frame: NSRect) {
        candidates.frame = frame
        candidates.layoutSubtreeIfNeeded()
        candidateShadow.frame = CandidateChrome.shadowFrame(around: frame, flipped: true)
        languageButton?.frame.origin.y = max(232, frame.maxY + 44)
    }
    private func showEmoji() {
        guard let window else { return }
        input.finish()
        let selection = editor.selectedRange()
        let anchor = window.convertToScreen(candidates.convert(candidates.bounds, to: nil))
        emojiPanel.present(near: anchor, onInsert: { [weak self] text in
            self?.editor.insertText(text, replacementRange: selection)
            self?.window?.makeFirstResponder(self?.editor)
        }, onDismiss: { [weak self] in self?.window?.makeFirstResponder(self?.editor) })
    }
    private func showModeIndicator() {
        guard Preferences.shared.showInputModeIndicator, page == .preview else { return }
        var range = NSRange(location: NSNotFound, length: 0)
        let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: &range)
        modeIndicator.present(mode: input.mode, modes: Preferences.shared.enabledInputModes, near: caret) { [weak self] mode in
            self?.input.selectMode(mode)
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        // Disabled search can emit editor/initialization notifications during first show.
        guard search.isEnabled, notification.object as? NSControl === search else { return }
        page = .home; buildBreadcrumbs(); buildPage(); layout(); scroll.contentView.scroll(to: .zero)
    }
    func render(to url: URL) throws {
        window?.displayIfNeeded(); root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let export = bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
        if let png = export.representation(using: .png, properties: [:]) { try png.write(to: url) }
    }
}
