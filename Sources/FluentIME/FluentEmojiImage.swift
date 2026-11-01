import AppKit

/// Original Microsoft Fluent Emoji assets, bundled locally under their MIT license.
enum FluentEmojiImage {
    private static let folder = Bundle.main.resourceURL?.appendingPathComponent("FluentEmoji")
    private static let names: [String: String] = {
        guard let url = folder?.appendingPathComponent("manifest.json"), let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return result
    }()
    private static var cache: [String: NSImage] = [:]
    private static let colorNames: [String: String] = {
        guard let url = folder?.appendingPathComponent("manifest-color.json"), let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return result
    }()
    static func image(for text: String, inline: Bool = false) -> NSImage? {
        let key = (inline ? "color:" : "3d:") + text
        if let image = cache[key] { return image }
        guard let filename = (inline ? colorNames[text] : nil) ?? names[text], let url = folder?.appendingPathComponent(filename), let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }
}
