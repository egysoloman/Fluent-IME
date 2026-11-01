import AppKit
// IME surfaces must remain above floating/full-screen application panels.
// Keep the emoji palette above candidates, and each shadow below its owner.
enum IMEPopupLevel {
    static let candidate = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
    static let emoji = NSWindow.Level(rawValue: candidate.rawValue + 1)
}
import FluentKit

/// Shared by the IMK popup, the settings preview, and component exports.
enum CandidateChrome {
    static let radius: CGFloat = 9
    static let rowHeight: CGFloat = 36
    static let sideMargin: CGFloat = 24
    static let topMargin: CGFloat = 16
    static let bottomMargin: CGFloat = 32

    static func shadowFrame(around surface: NSRect, flipped: Bool) -> NSRect {
        NSRect(x: surface.minX - sideMargin,
               y: surface.minY - (flipped ? topMargin : bottomMargin),
               width: surface.width + sideMargin * 2,
               height: surface.height + topMargin + bottomMargin)
    }

    static func fillPath(in frame: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
    }

    static func drawSurface(in frame: NSRect, theme: FluentTheme, fill: Bool = true) {
        // The translucent one-point edge lies outside the opaque face. In particular, the
        // lower edge blends with the shadow below it, as in the Windows reference.
        (theme.isDark ? theme.flyoutSurfaceFill : NSColor(srgbRed: 249/255, green: 249/255, blue: 249/255, alpha: 1)).setFill()
        if fill { fillPath(in: frame).fill() }
        theme.surfaceStrokeFlyout.setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        outline.lineWidth = 1
        outline.stroke()
    }

    static func shadowImage(size: NSSize, scale: CGFloat, theme: FluentTheme) -> NSImage? {
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // A fixed, unflipped bitmap context makes the shadow independent of AppKit's
        // on-screen backing-layer and cacheDisplay coordinate conventions.
        let surface = NSRect(x: sideMargin, y: bottomMargin,
                             width: size.width - sideMargin * 2, height: size.height - topMargin - bottomMargin)
        drawShadow(around: surface, bounds: NSRect(origin: .zero, size: size), scale: scale, theme: theme)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }

    private static func drawShadow(around surface: NSRect, bounds: NSRect, scale: CGFloat, theme: FluentTheme) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let face = fillPath(in: surface)
        let outside = NSBezierPath(rect: bounds)
        outside.append(face)
        outside.windingRule = .evenOdd
        outside.addClip()
        // Measured from the unscaled Windows reference: a broad downward shadow, with
        // almost no top halo. Quartz drawing also survives cacheDisplay exports.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(theme.isDark ? 0.32 : 0.14)
        // Shadow metrics use the bitmap's base coordinates, unaffected by its scaled CTM.
        shadow.shadowBlurRadius = 12 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.set()
        NSColor.black.setFill()
        face.fill()
    }
}

final class CandidateShadowView: NSView {
    var theme = IMEThemeObservation.current { didSet { needsDisplay = true } }
    private var appearanceObserver: IMEThemeObservation?
    private var cachedImage: NSImage?
    private var cachedSize = NSSize.zero
    private var cachedScale: CGFloat = 0
    private var cachedDark = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearanceObserver = IMEThemeObservation { [weak self] in self?.theme = $0 }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > CandidateChrome.sideMargin * 2,
              bounds.height > CandidateChrome.topMargin + CandidateChrome.bottomMargin else { return }
        let scale = window?.backingScaleFactor ?? 2
        if cachedImage == nil || cachedSize != bounds.size || cachedScale != scale || cachedDark != theme.isDark {
            cachedImage = CandidateChrome.shadowImage(size: bounds.size, scale: scale, theme: theme)
            cachedSize = bounds.size; cachedScale = scale; cachedDark = theme.isDark
        }
        cachedImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A separate, mouse-transparent child keeps shadow padding out of the IME's hit area.
final class CandidateShadowPanel: NSPanel {
    let shadowView = CandidateShadowView(frame: .zero)
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        animationBehavior = .none
        ignoresMouseEvents = true; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = shadowView
        setAccessibilityElement(false)
    }
}
