import AppKit
import FluentKit
import FluentIMECore

final class CandidateChoice: NSButton {
    var candidate = Candidate("") { didSet { if candidate != oldValue { hovered = false } } }
    var language: InputMode = .simplifiedChinese
    var number = 1
    var selected = false
    var theme = FluentTheme.current
    var invoke: (() -> Void)?
    var onHover: (() -> Void)?
    private var hovered = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init() {
        super.init(frame: .zero)
        isBordered = false; target = self; action = #selector(clicked)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func clicked() { invoke?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered {
            (selected ? theme.subtleFillSecondary : theme.subtleFillTertiary).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.75, width: bounds.width - 4, height: bounds.height - 1.5), xRadius: 5, yRadius: 5).fill()
        }
        if selected {
            theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0.5, y: 6, width: 3, height: bounds.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
        }
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: IMEFont.font(ofSize: 14.5, language: .english), .foregroundColor: theme.textSecondary]
        let label = "\(number)" as NSString
        let numberSize = label.size(withAttributes: numberAttributes)
        if number > 0 { label.draw(at: NSPoint(x: 12, y: (bounds.height - numberSize.height) / 2), withAttributes: numberAttributes) }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        if let image = FluentEmojiImage.image(for: candidate.text, inline: true) {
            FluentIconSource.image(image).draw(in: NSRect(x: 24, y: (bounds.height - 21) / 2, width: 21, height: 21), color: theme.textPrimary)
            return
        }
        let text = IMEFont.attributed(candidate.text, size: 14.5, language: language, color: theme.textPrimary)
        let height = text.size().height
        text.draw(in: NSRect(x: 24, y: (bounds.height - height) / 2, width: bounds.width - 30, height: height))
    }
}

/// Collapsed presentation has one row only. Preedit belongs to the IMK client.
final class CandidateView: NSView {
    private let material = FluentMaterialView(material: .nativeAcrylic)
    private let strip = NSScrollView()
    private let document = CandidateGridDocument()
    private let previous = makeChromeButton(.previous, label: L10n.candidatePrevious)
    private let next = makeChromeButton(.next, label: L10n.candidateNext)
    private let emoji = makeChromeButton(.palette, label: L10n.symbolsTitle)
    private let expand = makeChromeButton(.expand, label: L10n.candidateExpand)
    private var choices: [CandidateChoice] = []
    private var widths: [CGFloat] = []
    private var expanded = false
    private var theme = FluentTheme.current
    private var appearanceObserver: IMEThemeObservation?
    private var dividers: [NSView] = []
    private let pageMotion = IMEPageMotion()
    private var pageMotionGeneration = 0
    private var lastInput = ""
    private var lastPage = 0
    private var lastComposition: Composition?
    var language: InputMode = .simplifiedChinese
    private var lastLanguage: InputMode?
    private var lastFontSignature = ""
    private var lastMaxWidth: CGFloat = 0
    private var lastPageAnimation = true
    private var expansionEnabled = false
    private var scrollObserver: NSObjectProtocol?
    private var lastSelection = -1
    private var revealSelection = false
    private var hasMore = false
    private var loadingMore = false
    private let gridRowHeight: CGFloat = 28
    var onSelect: ((Int) -> Void)?
    var onPage: ((Bool) -> Void)?
    var onEmoji: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onLoadMore: (() -> Void)?
    var onViewportChanged: ((Int, Int) -> Void)?
    /// The expanded grid's row starts and how many candidates they cover.
    var onRowsChanged: (([Int], Int) -> Void)?
    /// Expanded rows hold as many candidates as fit, up to six, so long ones are not cut off.
    private var rows: [Range<Int>] = []
    private var gridWidths: [CGFloat] = []
    var onInteraction: (() -> Void)?
    var preferredSize = NSSize(width: 578, height: CandidateChrome.rowHeight)
    private var toolsWidth: CGFloat { expansionEnabled ? 110 : 83 }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.cornerRadius = CandidateChrome.radius; layer?.masksToBounds = true
        material.wantsLayer = true; material.layer?.cornerRadius = CandidateChrome.radius - 1; material.layer?.masksToBounds = true
        addSubview(material)
        strip.drawsBackground = false; strip.contentView.drawsBackground = false
        strip.hasHorizontalScroller = false; strip.hasVerticalScroller = false
        strip.scrollerStyle = .overlay
        strip.documentView = document; addSubview(strip)
        strip.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: strip.contentView, queue: .main) { [weak self] _ in self?.scrolled() }
        previous.onClick = { [weak self] in self?.onPage?(true) }
        next.onClick = { [weak self] in self?.onPage?(false) }
        emoji.onClick = { [weak self] in self?.onEmoji?() }
        expand.onClick = { [weak self] in
            self?.onInteraction?()
            Preferences.shared.expandedCandidates.toggle()
            self?.onLayoutChange?()
        }
        for button in [previous, next, emoji, expand] { addSubview(button) }
        for _ in 0..<3 {
            let divider = NSView(); divider.wantsLayer = true
            addSubview(divider); dividers.append(divider)
        }
        setAccessibilityRole(.group); setAccessibilityLabel(L10n.candidateAccessibility)
        appearanceObserver = IMEThemeObservation { [weak self] in self?.applyTheme($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

    func update(_ composition: Composition, maxWidth: CGFloat = 1100) {
        let pageAnimation = Preferences.shared.candidatePageAnimation
        if lastFontSignature == FontPreferences.signature, lastLanguage == language, lastComposition == composition, lastMaxWidth == maxWidth, expanded == Preferences.shared.expandedCandidates, lastPageAnimation == pageAnimation, expansionEnabled == Preferences.shared.candidateExpansionEnabled { return }
        lastFontSignature = FontPreferences.signature; lastLanguage = language
        lastComposition = composition; lastMaxWidth = maxWidth; lastPageAnimation = pageAnimation
        expansionEnabled = Preferences.shared.candidateExpansionEnabled
        let newInput = composition.rawInput != lastInput
        let wasExpanded = expanded
        expanded = Preferences.shared.expandedCandidates
        let paged = pageAnimation && !expanded && composition.rawInput == lastInput && composition.page != lastPage
        let snapshot = paged ? pageMotion.capture(strip.contentView) : nil
        let backward = composition.page < lastPage
        lastInput = composition.rawInput; lastPage = composition.page
        hasMore = composition.hasMoreCandidates
        revealSelection = newInput || expanded != wasExpanded || composition.highlighted != lastSelection
        lastSelection = composition.highlighted
        if newInput || expanded != wasExpanded { strip.contentView.scroll(to: .zero) }
        previous.isHidden = expanded; next.isHidden = expanded; emoji.isHidden = expanded
        dividers.forEach { $0.isHidden = expanded }
        expand.isHidden = !expansionEnabled
        dividers[2].isHidden = expanded || !expansionEnabled
        strip.hasVerticalScroller = expanded
        document.rowHeight = expanded ? gridRowHeight : 0
        previous.isEnabled = composition.page > 0
        next.isEnabled = !composition.isLastPage && !composition.candidates.isEmpty
        applyTheme(IMEThemeObservation.current)
        expand.setAccessibilityLabel(expanded ? L10n.candidateCollapse : L10n.candidateExpand)
        expand.toolTip = expanded ? L10n.candidateCollapse : L10n.candidateExpand
        while choices.count > composition.candidates.count { choices.removeLast().removeFromSuperview() }
        widths = composition.candidates.map { min(190, max(66, ceil(IMEFont.attributed($0.text, size: 14.5, language: language, color: theme.textPrimary).size().width) + 36)) }
        for (index, candidate) in composition.candidates.enumerated() {
            let button: CandidateChoice
            if index < choices.count { button = choices[index] }
            else { button = CandidateChoice(); choices.append(button); document.addSubview(button) }
            button.language = language; button.candidate = candidate; button.number = index + 1
            button.selected = index == composition.highlighted; button.theme = theme
            button.setAccessibilityLabel(L10n.candidateItem(index + 1, candidate.text))
            button.setAccessibilityValue(button.selected ? L10n.candidateSelected : "")
            button.toolTip = candidate.comment.isEmpty ? candidate.text : "\(candidate.text) · \(candidate.comment)"
            button.invoke = { [weak self] in self?.onSelect?(index) }
            button.onHover = { [weak self] in self?.onInteraction?() }
            button.needsDisplay = true
        }
        let naturalWidth = max(300, widths.reduce(0, +) + toolsWidth + 6)
        // Expanded width is independent of total candidate count. The content grows
        // vertically and is fetched lazily; it is not another seven-item page.
        let gridWidth = max(400, min(560, ((widths.prefix(7).max() ?? 66) - 6) * 6 + 36))
        let width = min(maxWidth, expanded ? gridWidth : naturalWidth)
        if expanded { flowRows(width: max(1, width - 36)) } else { rows = []; gridWidths = [] }
        preferredSize = NSSize(width: width, height: expanded ? CGFloat(min(5, max(1, rows.count))) * gridRowHeight + 8 : CandidateChrome.rowHeight)
        needsLayout = true
        layoutSubtreeIfNeeded()
        pageMotionGeneration += 1
        let generation = pageMotionGeneration
        pageMotion.cancel()
        if let snapshot {
            // The panel/preview owner applies preferredSize after update returns.
            // Begin once that layout is final, otherwise the resize cancels playback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pageMotionGeneration == generation, Preferences.shared.candidatePageAnimation else { return }
                self.pageMotion.play(snapshot, in: self.strip.contentView, content: self.document, backward: backward)
            }
        }
        scrolled()
    }

    private func applyTheme(_ updated: FluentTheme) {
        if updated != theme { pageMotion.cancel() }
        theme = updated
        material.fluentTheme = theme; material.isMaterialEnabled = Preferences.shared.advancedEffects
        material.isHidden = !Preferences.shared.advancedEffects; material.state = .active
        material.fallbackColor = theme.isDark ? theme.flyoutSurfaceFill : NSColor(srgbRed: 249/255, green: 249/255, blue: 249/255, alpha: 1)
        document.dividerColor = theme.divider; document.needsDisplay = true
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        needsDisplay = true
        for (button, glyph) in [(previous, IMEGlyph.previous), (next, .next), (emoji, .palette), (expand, expanded ? .collapse : .expand)] {
            // FluentButton already applies 40% opacity to a disabled non-template image.
            let ink = button.isEnabled ? theme.textPrimary : (theme.isDark ? .white : NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            button.theme = theme; button.image = glyph.image(color: ink)
        }
        dividers.forEach { $0.layer?.backgroundColor = theme.divider.cgColor }
        choices.forEach { $0.theme = theme; $0.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        CandidateChrome.drawSurface(in: bounds, theme: theme, fill: !Preferences.shared.advancedEffects)
    }

    override func layout() {
        super.layout()
        material.frame = bounds.insetBy(dx: 1, dy: 1)
        let toolbarX = bounds.width - toolsWidth - 1
        previous.frame = NSRect(x: toolbarX + 3, y: 4, width: 24, height: 28)
        next.frame = NSRect(x: toolbarX + 27, y: 4, width: 24, height: 28)
        emoji.frame = NSRect(x: toolbarX + 54, y: 4, width: 28, height: 28)
        expand.frame = NSRect(x: toolbarX + 83, y: 4, width: 27, height: 28)
        if expanded { expand.frame = NSRect(x: bounds.width - 29, y: 4, width: 25, height: 28) }
        strip.frame = expanded ? NSRect(x: 4, y: 4, width: max(1, bounds.width - 36), height: max(1, bounds.height - 8))
            : NSRect(x: 4, y: 4, width: max(1, toolbarX - 4), height: 28)
        document.frame = NSRect(x: 0, y: 0, width: expanded ? strip.bounds.width : widths.reduce(0, +), height: expanded ? max(strip.bounds.height, CGFloat(rows.count) * gridRowHeight) : 28)
        var x: CGFloat = 0
        for (index, choice) in choices.enumerated() where !expanded {
            choice.frame = NSRect(x: x, y: 0, width: widths[index], height: 28)
            x += widths[index]
        }
        for (row, range) in rows.enumerated() where expanded {
            var left: CGFloat = 0
            for index in range where choices.indices.contains(index) {
                choices[index].frame = NSRect(x: left, y: CGFloat(row) * gridRowHeight, width: gridWidths[index], height: gridRowHeight - 1)
                left += gridWidths[index]
            }
        }
        if (!expanded || revealSelection), let selected = choices.first(where: \.selected) { document.scrollToVisible(selected.frame) }
        revealSelection = false
        for (index, offset) in [CGFloat(0), 53, 82].enumerated() { dividers[index].frame = NSRect(x: toolbarX + offset, y: 4, width: 0.5, height: 28) }
    }
    /// Packs candidates into rows by their natural width. Full rows are stretched to the
    /// grid width; a shorter last row keeps its natural widths.
    private func flowRows(width: CGFloat) {
        let natural = choices.map { choice in
            // CandidateChoice draws text from x 24 with 6 pt to spare; an emoji is 21 pt wide.
            min(width, max(52, ceil(IMEFont.attributed(choice.candidate.text, size: 14.5, language: language, color: theme.textPrimary).size().width) + 32))
        }
        rows = []; gridWidths = natural
        var start = 0, used: CGFloat = 0
        for index in natural.indices {
            if index > start, used + natural[index] > width || index - start == 6 {
                rows.append(start..<index); start = index; used = 0
            }
            used += natural[index]
        }
        if start < natural.count || rows.isEmpty { rows.append(start..<natural.count) }
        for (row, range) in rows.enumerated() where !range.isEmpty && (row < rows.count - 1 || range.count == 6) {
            let extra = (width - range.reduce(CGFloat(0)) { $0 + natural[$1] }) / CGFloat(range.count)
            for index in range { gridWidths[index] = natural[index] + max(0, extra) }
        }
        onRowsChanged?(rows.map(\.lowerBound), natural.count)
    }
    private func scrolled() {
        guard expanded else { return }
        let visible = strip.contentView.bounds
        // Keyboard navigation numbers the active row. After wheel scrolling
        // moves that row out of view, number the first complete visible row.
        let selected = choices.firstIndex { $0.selected && visible.contains($0.frame) }
        let numbered = selected.flatMap { item in rows.first { $0.contains(item) } }
            ?? rows[min(max(0, Int(ceil(visible.minY / gridRowHeight))), max(0, rows.count - 1))]
        for (index, choice) in choices.enumerated() {
            choice.number = numbered.contains(index) ? index - numbered.lowerBound + 1 : 0
            choice.setAccessibilityLabel(choice.number > 0 ? "\(choice.number)，\(choice.candidate.text)" : choice.candidate.text)
            choice.needsDisplay = true
        }
        onViewportChanged?(numbered.lowerBound, max(1, numbered.count))
        if hasMore, !loadingMore, strip.contentView.bounds.maxY >= document.bounds.height - 2 * gridRowHeight {
            loadingMore = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingMore = false
                if self.expanded && self.hasMore && self.strip.contentView.bounds.maxY >= self.document.bounds.height - 2 * self.gridRowHeight { self.onLoadMore?() }
            }
        }
    }
}

final class CandidatePanel: NSPanel {
    let candidateView = CandidateView(frame: .zero)
    private let shadowPanel = CandidateShadowPanel()
    private var revealTimer: Timer?
    private var resizeTimer: Timer?
    private var resizeTarget: NSRect?
    private var presentedExpansion: Bool?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        // WindowServer's independent popup zoom moves the face away from its shadow,
        // and a hide/reopen can replay the previous position. Animate content only.
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false; isFloatingPanel = true; contentView = candidateView
        // Setting isFloatingPanel resets NSPanel.level to .floating (3).
        // Apply our actual overlay level after configuring panel behavior.
        level = IMEPopupLevel.candidate
        shadowPanel.level = level
    }
    override func orderOut(_ sender: Any?) {
        resizeTimer?.invalidate(); resizeTimer = nil
        resizeTarget = nil
        presentedExpansion = nil
        shadowPanel.orderOut(sender)
        super.orderOut(sender)
        finishReveal()
    }
    private func finishReveal() {
        revealTimer?.invalidate(); revealTimer = nil
        alphaValue = 1; shadowPanel.alphaValue = 1
    }
    private var shouldAnimateReveal: Bool {
        Preferences.shared.candidatePopupAnimation && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private func animateReveal() {
        let start = ProcessInfo.processInfo.systemUptime
        // One clock drives both windows; their geometry never participates in a popup zoom.
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.12)
            guard self.isVisible, self.shouldAnimateReveal, progress < 1 else { self.finishReveal(); return }
            let opacity = 1 - pow(1 - progress, 3)
            self.alphaValue = opacity; self.shadowPanel.alphaValue = opacity
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    deinit { revealTimer?.invalidate(); resizeTimer?.invalidate() }
    private func applyFrame(_ target: NSRect) {
        NSDisableScreenUpdates()
        defer { NSEnableScreenUpdates() }
        if frame != target { setFrame(target, display: false) }
        candidateView.layoutSubtreeIfNeeded()
        let shadowFrame = CandidateChrome.shadowFrame(around: target, flipped: false)
        if shadowPanel.frame != shadowFrame { shadowPanel.setFrame(shadowFrame, display: false) }
    }
    private func resize(to target: NSRect, animated: Bool) {
        if resizeTimer != nil && resizeTarget == target { return }
        resizeTarget = target
        resizeTimer?.invalidate(); resizeTimer = nil
        guard animated, frame != target else { applyFrame(target); return }
        let initial = frame, start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.16)
            let progress = 1 - pow(1 - t, 3)
            func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
            self.applyFrame(NSRect(x: blend(initial.minX, target.minX), y: blend(initial.minY, target.minY), width: blend(initial.width, target.width), height: blend(initial.height, target.height)))
            if t >= 1 { self.resizeTimer?.invalidate(); self.resizeTimer = nil }
        }
        resizeTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func present(_ composition: Composition, caret: NSRect) {
        // Zhuyin composes inline and shows candidates only once the list is opened.
        guard composition.isComposing, !composition.candidates.isEmpty else { orderOut(nil); return }
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let reveal = !isVisible && shouldAnimateReveal
        if !isVisible || !shouldAnimateReveal { finishReveal() }
        if reveal { alphaValue = 0; shadowPanel.alphaValue = 0 }
        candidateView.update(composition, maxWidth: screen.visibleFrame.width - 16)
        let target = PanelPlacement.frame(size: candidateView.preferredSize, caret: caret, screen: screen.visibleFrame, gap: 4)
        let expansion = Preferences.shared.expandedCandidates
        let animateResize = isVisible && presentedExpansion != nil && presentedExpansion != expansion && Preferences.shared.candidateExpansionAnimation && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        presentedExpansion = expansion
        shadowPanel.shadowView.theme = IMEThemeObservation.current
        resize(to: target, animated: animateResize)
        if !isVisible { shadowPanel.orderFrontRegardless() }
        orderFrontRegardless()
        // AppKit detaches an explicitly ordered-out child. Reattach on every reveal so
        // the second and later compositions keep their shadow in the same window group.
        if !(childWindows?.contains(where: { $0 === shadowPanel }) ?? false) {
            addChildWindow(shadowPanel, ordered: .below)
        }
        if reveal { animateReveal() }
    }
}

private final class CandidateGridDocument: NSView {
    override var isFlipped: Bool { true }
    var rowHeight: CGFloat = 0
    var dividerColor = NSColor.separatorColor
    override func draw(_ dirtyRect: NSRect) {
        guard rowHeight > 0 else { return }
        dividerColor.withAlphaComponent(0.08).setStroke()
        let path = NSBezierPath(); path.lineWidth = 0.5
        for y in stride(from: rowHeight, to: bounds.height, by: rowHeight) {
            path.move(to: NSPoint(x: 0, y: y - 0.5)); path.line(to: NSPoint(x: bounds.width, y: y - 0.5))
        }
        path.stroke()
    }
}
