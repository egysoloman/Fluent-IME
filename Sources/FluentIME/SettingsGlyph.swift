import AppKit

/// Reference-style symbols drawn in a common 22 pt em square, with unscaled stroke widths.
/// The caller uses FluentIconSource's aspect-fit rendering instead of stretching NSImage.
enum SettingsGlyph {
    case general, keyboard, appearance, dictionary, advanced, clipboard
    func image(color: NSColor) -> NSImage {
        if self == .clipboard { return IMEGlyph.clipboard.image(color: color) }
        return NSImage(size: NSSize(width: 22, height: 22), flipped: true) { _ in
            color.setFill(); color.setStroke()
            let p = NSBezierPath(); p.lineWidth = 1.15; p.lineCapStyle = .round; p.lineJoinStyle = .round
            switch self {
            case .clipboard: break
            case .general:
                ("A" as NSString).draw(at: NSPoint(x: 0, y: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .regular), .foregroundColor: color])
                ("字" as NSString).draw(at: NSPoint(x: 11, y: -1), withAttributes: [.font: IMEFont.font(ofSize: 11), .foregroundColor: color])
                p.move(to: NSPoint(x: 12, y: 12)); p.line(to: NSPoint(x: 18, y: 12)); p.stroke()
            case .keyboard:
                let border = NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 20, height: 14), xRadius: 2, yRadius: 2)
                border.lineWidth = 1.3; border.stroke()
                for y in [7.5, 11.0] {
                    for x in [4.0, 7.5, 11.0, 14.5, 18.0] { NSBezierPath(roundedRect: NSRect(x: x - 0.65, y: y, width: 1.3, height: 1.3), xRadius: 0.3, yRadius: 0.3).fill() }
                }
                p.move(to: NSPoint(x: 7, y: 15)); p.line(to: NSPoint(x: 15, y: 15)); p.stroke()
            case .appearance:
                ("字" as NSString).draw(at: NSPoint(x: 0, y: -2), withAttributes: [.font: IMEFont.font(ofSize: 13), .foregroundColor: color])
                p.move(to: NSPoint(x: 9, y: 21)); p.line(to: NSPoint(x: 12.5, y: 20))
                p.line(to: NSPoint(x: 21, y: 9)); p.curve(to: NSPoint(x: 18.3, y: 6.9), controlPoint1: NSPoint(x: 21.8, y: 7.5), controlPoint2: NSPoint(x: 19.8, y: 6))
                p.line(to: NSPoint(x: 9.7, y: 18)); p.close()
                p.move(to: NSPoint(x: 16.5, y: 9.1)); p.line(to: NSPoint(x: 19.2, y: 11.2)); p.stroke()
            case .dictionary:
                let book = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2, width: 12.5, height: 18), xRadius: 2, yRadius: 2)
                book.lineWidth = 1.2; book.stroke()
                p.move(to: NSPoint(x: 4, y: 6)); p.line(to: NSPoint(x: 10.5, y: 6))
                p.move(to: NSPoint(x: 4, y: 9)); p.line(to: NSPoint(x: 9, y: 9)); p.stroke()
                // Paint a small background gap before the person overlaps the book outline.
                NSGraphicsContext.saveGraphicsState()
                let gap = NSBezierPath(roundedRect: NSRect(x: 12.2, y: 8.5, width: 9.8, height: 13.5), xRadius: 3, yRadius: 3)
                NSGraphicsContext.current?.compositingOperation = .clear
                gap.fill()
                NSGraphicsContext.restoreGraphicsState()
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14.5, y: 9.5, width: 5, height: 5)).fill()
                NSBezierPath(roundedRect: NSRect(x: 12.5, y: 16, width: 9, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            case .advanced:
                func gear(_ center: NSPoint, radius: CGFloat) {
                    let outline = NSBezierPath(); outline.lineWidth = 1.05; outline.lineJoinStyle = .round
                    for i in 0..<32 {
                        let angle = CGFloat(i) * .pi / 16
                        let r = i % 4 == 0 || i % 4 == 3 ? radius * 0.72 : radius
                        let point = NSPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                        if i == 0 { outline.move(to: point) } else { outline.line(to: point) }
                    }
                    outline.close(); outline.stroke()
                    let hole = NSBezierPath(ovalIn: NSRect(x: center.x - radius * 0.3, y: center.y - radius * 0.3, width: radius * 0.6, height: radius * 0.6))
                    hole.lineWidth = 1.05; hole.stroke()
                }
                gear(NSPoint(x: 6, y: 6), radius: 4.8); gear(NSPoint(x: 15.4, y: 15.4), radius: 5.6)
            }
            return true
        }
    }
}
