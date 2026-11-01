import Foundation

/// Resolves only this product's installer, or the image that actually contains it.
/// A translocated or unrecognised read-only location is left untouched.
public enum InstallerCleanup {
    public struct Target { public let item: URL; public let mountedVolume: URL? }
    public static func target(installer: URL, readOnly: Bool, diskImages: [String: Any] = [:]) throws -> Target {
        let installer = installer.standardizedFileURL
        guard installer.pathExtension == "app",
              let info = NSDictionary(contentsOf: installer.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == "org.fluentime.installer" else { throw CocoaError(.fileReadCorruptFile) }
        if !readOnly { return Target(item: installer, mountedVolume: nil) }
        for image in diskImages["images"] as? [[String: Any]] ?? [] {
            guard let path = image["image-path"] as? String, path.hasPrefix("/"), path.hasSuffix(".dmg") else { continue }
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                guard let mount = entity["mount-point"] as? String else { continue }
                let volume = URL(fileURLWithPath: mount).standardizedFileURL
                guard volume.path.hasPrefix("/Volumes/"), installer.path.hasPrefix(volume.path + "/") else { continue }
                return Target(item: URL(fileURLWithPath: path), mountedVolume: volume)
            }
        }
        throw CocoaError(.fileWriteVolumeReadOnly)
    }
}
