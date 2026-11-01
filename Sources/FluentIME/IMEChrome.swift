import AppKit
import FluentKit
import FluentIMECore

enum IMEFont {
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular, language: InputMode? = nil) -> NSFont {
        FontPreferences.font(size: size, weight: weight, language: language ?? FontPreferences.interfaceMode)
    }
    private static var providerSignature = ""
    private static var cachedProvider = FluentFontProvider { _, size, weight in font(ofSize: size, weight: weight) }
    static var provider: FluentFontProvider {
        let signature = FontPreferences.signature
        if signature != providerSignature {
            providerSignature = signature
            cachedProvider = FluentFontProvider { _, size, weight in font(ofSize: size, weight: weight) }
        }
        return cachedProvider
    }
    static func attributed(_ text: String, size: CGFloat, language: InputMode, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font(ofSize: size, language: language), .foregroundColor: color])
        var offset = 0
        for character in text {
            let value = String(character), length = (String(character) as NSString).length
            if character.isASCII { result.addAttribute(.font, value: font(ofSize: size, language: .english), range: NSRange(location: offset, length: length)) }
            offset += (value as NSString).length
        }
        return result
    }
}

class IMEFlippedView: NSView { override var isFlipped: Bool { true } }

struct IMEToolbarStyle: FluentButtonStyle {
    func appearance(for configuration: FluentButtonStyleConfiguration) -> FluentButtonAppearance {
        let theme = configuration.theme
        let hovered = configuration.controlState == .pointerOver || configuration.controlState == .pressed
        return FluentButtonAppearance(backgroundColor: hovered ? theme.subtleFillSecondary : .clear,
                                      foregroundColor: configuration.isEnabled ? theme.textPrimary : theme.textDisabled,
                                      borderColor: .clear, borderWidth: 0, cornerRadius: 4,
                                      contentInsets: NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3), focusRingColor: theme.accent)
    }
}

struct IMECompactButtonStyle: FluentButtonStyle {
    func appearance(for configuration: FluentButtonStyleConfiguration) -> FluentButtonAppearance {
        let base = FluentAutomaticButtonStyle().appearance(for: configuration)
        return FluentButtonAppearance(backgroundColor: base.backgroundColor, foregroundColor: base.foregroundColor,
                                      borderColor: base.borderColor, borderGradientColors: base.borderGradientColors,
                                      borderWidth: base.borderWidth, cornerRadius: base.cornerRadius,
                                      contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4),
                                      focusRingColor: base.focusRingColor, focusRingWidth: base.focusRingWidth)
    }
}

func makeChromeButton(_ glyph: IMEGlyph, label: String) -> FluentButton {
    let button = FluentButton(title: "")
    button.image = glyph.image(color: Preferences.shared.theme.textPrimary)
    // Empty-title overlap mode uses our 3 pt insets, avoiding image-only padding
    // that shrinks the 22 pt reference glyph inside a compact candidate button.
    button.imagePosition = .imageOverlaps; button.fluentStyle = IMEToolbarStyle()
    button.fluentControlSize = .small; button.refusesFirstResponder = true
    button.toolTip = label; button.setAccessibilityLabel(label)
    return button
}

enum IMEGlyph {
    case previous, next, palette, expand, collapse, close, smile, gif, kaomoji, symbols, clipboard, search, back, chevronRight, pin, more
    func image(color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: true) { _ in
            color.setStroke(); color.setFill()
            let path = NSBezierPath(); path.lineWidth = 1.3; path.lineCapStyle = .round; path.lineJoinStyle = .round
            switch self {
            case .more:
                for x in [5.0, 11.0, 17.0] { NSBezierPath(ovalIn: NSRect(x: x - 1, y: 10, width: 2, height: 2)).fill() }
            case .pin:
                path.move(to: NSPoint(x: 8, y: 3)); path.line(to: NSPoint(x: 16, y: 3))
                path.line(to: NSPoint(x: 14, y: 6)); path.line(to: NSPoint(x: 14, y: 11))
                path.line(to: NSPoint(x: 17, y: 14)); path.line(to: NSPoint(x: 7, y: 14))
                path.line(to: NSPoint(x: 10, y: 11)); path.line(to: NSPoint(x: 10, y: 6)); path.close(); path.stroke()
                path.move(to: NSPoint(x: 12, y: 14)); path.line(to: NSPoint(x: 12, y: 20)); path.stroke()
            case .previous, .next:
                let right = self == .next
                func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: right ? x : 22 - x, y: y) }
                path.move(to: point(8, 7.8))
                path.curve(to: point(9.2, 7.1), controlPoint1: point(8, 7), controlPoint2: point(8.6, 6.8))
                path.line(to: point(14, 10.3))
                path.curve(to: point(14, 11.7), controlPoint1: point(14.8, 10.8), controlPoint2: point(14.8, 11.2))
                path.line(to: point(9.2, 14.9))
                path.curve(to: point(8, 14.2), controlPoint1: point(8.6, 15.2), controlPoint2: point(8, 15))
                path.close(); path.fill()
            case .expand, .collapse:
                path.lineWidth = 1
                path.move(to: NSPoint(x: 5, y: self == .expand ? 8 : 14)); path.line(to: NSPoint(x: 11, y: self == .expand ? 14 : 8))
                path.line(to: NSPoint(x: 17, y: self == .expand ? 8 : 14)); path.stroke()
            case .close:
                path.move(to: NSPoint(x: 5, y: 5)); path.line(to: NSPoint(x: 17, y: 17))
                path.move(to: NSPoint(x: 17, y: 5)); path.line(to: NSPoint(x: 5, y: 17)); path.stroke()
            case .palette:
                var fitting = AffineTransform(translationByX: 1.32, byY: 1.32)
                fitting.scale(0.88)
                (fitting as NSAffineTransform).concat()
                // Open rounded square and a separate upper-right heart: no line through the heart.
                let outline = NSBezierPath(); outline.lineWidth = 1.15; outline.lineCapStyle = .round
                outline.move(to: NSPoint(x: 7.7, y: 4.6))
                outline.curve(to: NSPoint(x: 4, y: 8), controlPoint1: NSPoint(x: 5.3, y: 4.6), controlPoint2: NSPoint(x: 4, y: 5.8))
                outline.line(to: NSPoint(x: 4, y: 16.8))
                outline.curve(to: NSPoint(x: 6.8, y: 19.5), controlPoint1: NSPoint(x: 4, y: 18.5), controlPoint2: NSPoint(x: 5.1, y: 19.5))
                outline.line(to: NSPoint(x: 15.2, y: 19.5))
                outline.curve(to: NSPoint(x: 18, y: 16.8), controlPoint1: NSPoint(x: 16.9, y: 19.5), controlPoint2: NSPoint(x: 18, y: 18.5))
                outline.line(to: NSPoint(x: 18, y: 12)); outline.stroke()
                path.move(to: NSPoint(x: 15.2, y: 13.2))
                path.curve(to: NSPoint(x: 9.7, y: 7.1), controlPoint1: NSPoint(x: 13.9, y: 12), controlPoint2: NSPoint(x: 9.7, y: 9.1))
                path.curve(to: NSPoint(x: 15.2, y: 3.8), controlPoint1: NSPoint(x: 8.8, y: 2.6), controlPoint2: NSPoint(x: 12.8, y: 1.7))
                path.curve(to: NSPoint(x: 20.7, y: 7.1), controlPoint1: NSPoint(x: 17.6, y: 1.7), controlPoint2: NSPoint(x: 21.6, y: 2.6))
                path.curve(to: NSPoint(x: 15.2, y: 13.2), controlPoint1: NSPoint(x: 20.7, y: 9.1), controlPoint2: NSPoint(x: 16.5, y: 12)); path.fill()
            case .chevronRight:
                path.lineWidth = 1
                path.move(to: NSPoint(x: 9, y: 6)); path.line(to: NSPoint(x: 14, y: 11)); path.line(to: NSPoint(x: 9, y: 16)); path.stroke()
            case .smile:
                let circle = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 17, height: 17)); circle.lineWidth = 1.3; circle.stroke()
                for x in [7.0, 14.0] { NSBezierPath(ovalIn: NSRect(x: x, y: 7, width: 1.8, height: 1.8)).fill() }
                path.move(to: NSPoint(x: 7, y: 13)); path.curve(to: NSPoint(x: 15, y: 13), controlPoint1: NSPoint(x: 9, y: 17), controlPoint2: NSPoint(x: 13, y: 17)); path.stroke()
            case .gif:
                let border = NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 20, height: 14), xRadius: 3, yRadius: 3); border.lineWidth = 1.3; border.stroke()
                ("GIF" as NSString).draw(at: NSPoint(x: 3, y: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: color])
            case .kaomoji:
                (";-)" as NSString).draw(at: NSPoint(x: 1, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: color])
            case .symbols:
                for (index, text) in ["% μ", "Δ +"].enumerated() {
                    (text as NSString).draw(at: NSPoint(x: 2, y: CGFloat(index) * 10), withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: color])
                }
            case .clipboard:
                let border = NSBezierPath(roundedRect: NSRect(x: 5, y: 4, width: 13, height: 16), xRadius: 1.5, yRadius: 1.5); border.lineWidth = 1.3; border.stroke()
                let clip = NSBezierPath(roundedRect: NSRect(x: 8, y: 2, width: 7, height: 4), xRadius: 1, yRadius: 1); clip.lineWidth = 1.3; clip.stroke()
                for y in [10.0, 14, 17] { path.move(to: NSPoint(x: 8, y: y)); path.line(to: NSPoint(x: 14, y: y)) }; path.stroke()
            case .search:
                let circle = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 11, height: 11)); circle.lineWidth = 1.3; circle.stroke()
                path.move(to: NSPoint(x: 13, y: 13)); path.line(to: NSPoint(x: 19, y: 19)); path.stroke()
            case .back:
                path.lineWidth = 1.2
                path.move(to: NSPoint(x: 18, y: 11)); path.line(to: NSPoint(x: 4, y: 11))
                path.move(to: NSPoint(x: 10, y: 5)); path.line(to: NSPoint(x: 4, y: 11)); path.line(to: NSPoint(x: 10, y: 17)); path.stroke()
            }
            return true
        }
    }
}
