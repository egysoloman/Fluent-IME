import AppKit

public enum CaretAnchor {
    /// Prefer IMK's full line-height rectangle. Some IMK proxies return subnormal
    /// garbage from firstRect even when the method exists. Only use document
    /// offsets as a validated fallback; attributesForCharacterIndex is inline-relative.
    public static func resolve(marked: NSRange, selected: NSRange, screens: [NSRect], documentRect: (NSRange) -> NSRect, inlineRect: () -> NSRect) -> NSRect? {
        if let rectangle = valid(inlineRect(), screens: screens) { return rectangle }
        let location = marked.location != NSNotFound ? marked.location : selected.location
        if location != NSNotFound, let rectangle = valid(documentRect(NSRange(location: location, length: 0)), screens: screens) { return rectangle }
        return nil
    }
    private static func valid(_ raw: NSRect, screens: [NSRect]) -> NSRect? {
        guard [raw.origin.x, raw.origin.y, raw.size.width, raw.size.height].allSatisfy(\.isFinite), abs(raw.height) >= 1, abs(raw.height) < 512 else { return nil }
        var rectangle = raw.standardized
        rectangle.size.width = max(1, rectangle.width)
        guard screens.contains(where: { $0.intersects(rectangle) }) else { return nil }
        return rectangle
    }
}
