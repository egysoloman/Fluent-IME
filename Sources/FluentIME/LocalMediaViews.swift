import AppKit
import FluentKit
import FluentIMECore

final class GIFPreviewButton: NSButton {
    var invoke: (() -> Void)?
    var theme = FluentTheme.current { didSet { needsDisplay = true } }
    private let preview = NSImageView()
    init(url: URL, name: String) {
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(clicked)
        setAccessibilityLabel(L10n.gifCopyAccessibility(name)); toolTip = name
        preview.image = NSImage(contentsOf: url); preview.imageScaling = .scaleProportionallyUpOrDown
        preview.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        addSubview(preview)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { invoke?() }
    override func layout() { super.layout(); preview.frame = bounds.insetBy(dx: 4, dy: 4) }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {
        theme.controlFill.setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        shape.fill(); theme.controlStroke.setStroke(); shape.lineWidth = 0.5; shape.stroke()
    }
}

final class ClipboardTextButton: NSButton {
    var invoke: (() -> Void)?
    var theme = FluentTheme.current { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    init(_ text: String) {
        super.init(frame: .zero)
        title = String(text.prefix(140)); isBordered = false
        target = self; action = #selector(clicked); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { invoke?() }
    override func draw(_ dirtyRect: NSRect) {
        theme.controlFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: bounds.insetBy(dx: 10, dy: 8), withAttributes: [
            .font: IMEFont.font(ofSize: 13), .foregroundColor: theme.textPrimary, .paragraphStyle: paragraph
        ])
    }
}

private final class ClipboardCardBody: NSButton {
    let entry: ClipboardEntry
    let thumbnail: NSImage?
    var theme = FluentTheme.current
    var invoke: (() -> Void)?
    override var isFlipped: Bool { true }
    init(_ entry: ClipboardEntry) {
        self.entry = entry; thumbnail = entry.thumbnail()
        super.init(frame: .zero); isBordered = false; title = ""
        target = self; action = #selector(clicked)
        setAccessibilityLabel(entry.text.isEmpty ? entry.kindTitle : String(entry.text.prefix(140)))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { invoke?() }
    override func draw(_ dirtyRect: NSRect) {
        if let image = thumbnail {
            let area = NSRect(x: 8, y: 8, width: min(136, bounds.width - 16), height: bounds.height - 16)
            let ratio = min(area.width / max(1, image.size.width), area.height / max(1, image.size.height))
            image.draw(in: NSRect(x: area.minX, y: area.minY, width: image.size.width * ratio, height: image.size.height * ratio), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let text = entry.text.isEmpty ? entry.kindTitle : String(entry.text.prefix(240))
            (text as NSString).draw(in: bounds.insetBy(dx: 12, dy: 10), withAttributes: [.font: IMEFont.font(ofSize: 13), .foregroundColor: theme.textPrimary, .paragraphStyle: paragraph])
        }
    }
}

extension ClipboardEntry {
    var kindTitle: String {
        switch kind {
        case .text: return L10n.clipboardKindText
        case .richText: return L10n.clipboardKindRichText
        case .image: return L10n.clipboardKindImage
        case .files: return L10n.clipboardKindFiles
        case .link: return L10n.clipboardKindLink
        }
    }
}

final class ClipboardCard: NSView {
    private var flyout: FluentMenuFlyout?
    private let body: ClipboardCardBody
    private let more = makeChromeButton(.more, label: L10n.clipboardMore)
    private let pin: FluentButton
    var selectionHighlighted = false { didSet { applyTheme() } }
    var onSelect: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var onRemove: (() -> Void)?
    var theme = FluentTheme.current { didSet { applyTheme() } }
    override var isFlipped: Bool { true }
    init(_ entry: ClipboardEntry) {
        body = ClipboardCardBody(entry)
        pin = makeChromeButton(.pin, label: entry.isPinned ? L10n.clipboardUnpin : L10n.clipboardPin)
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 5; layer?.borderWidth = 0.5
        for view in [body, more, pin] { addSubview(view) }
        body.invoke = { [weak self] in self?.onSelect?() }
        pin.onClick = { [weak self] in self?.onPin?() }
        more.onClick = { [weak self] in guard let self else { return }; self.showActions() }
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); body.frame = NSRect(x: 0, y: 0, width: bounds.width - 38, height: bounds.height)
        more.frame = NSRect(x: bounds.width - 32, y: 4, width: 26, height: 24)
        pin.frame = NSRect(x: bounds.width - 32, y: bounds.height - 30, width: 26, height: 24)
    }
    private func applyTheme() {
        layer?.backgroundColor = theme.controlFill.cgColor
        layer?.borderWidth = selectionHighlighted ? 2 : 0.5
        layer?.borderColor = (selectionHighlighted ? theme.accent : theme.controlStroke.withAlphaComponent(0.25)).cgColor
        body.theme = theme; body.needsDisplay = true
        more.theme = theme; more.image = IMEGlyph.more.image(color: theme.textPrimary)
        flyout?.update(items: menuItems(), theme: theme)
        pin.theme = theme; pin.image = IMEGlyph.pin.image(color: body.entry.isPinned ? theme.accent : theme.textSecondary)
    }
    private func menuItems() -> [FluentMenuItem] {
        [FluentMenuItem(id: "copy", L10n.clipboardCopy) { [weak self] in self?.onCopy?() },
         FluentMenuItem(id: "pin", body.entry.isPinned ? L10n.clipboardUnpin : L10n.clipboardPin) { [weak self] in self?.onPin?() },
         FluentMenuItem(id: "delete", L10n.clipboardDeleteEntry) { [weak self] in self?.onRemove?() }]
    }
    private func showActions() {
        flyout = FluentMenuFlyout(items: menuItems(), theme: theme, matchesAnchorWidth: false)
        flyout?.present(relativeTo: more)
    }
    override func rightMouseDown(with event: NSEvent) { showActions() }

}
