import Foundation

private class ResourceFinder {}

public enum FluentIMEResources {
    public static let bundle: Bundle = {
        let bundleName = "FluentIME_FluentIMECore.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.bundleURL,
            Bundle(for: ResourceFinder.self).resourceURL?.appendingPathComponent(bundleName),
            Bundle(for: ResourceFinder.self).resourceURL,
            Bundle(for: ResourceFinder.self).bundleURL.appendingPathComponent(bundleName),
            Bundle(for: ResourceFinder.self).bundleURL
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if let b = Bundle(url: candidate),
               b.url(forResource: "emoji-search", withExtension: "json") != nil ||
               b.path(forResource: "zh-Hans", ofType: "lproj") != nil ||
               (try? FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil))?.contains(where: { $0.lastPathComponent.hasSuffix(".lproj") }) == true {
                return b
            }
        }

        return Bundle.main
    }()
}
