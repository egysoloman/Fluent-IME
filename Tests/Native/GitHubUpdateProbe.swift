import Foundation
import FluentIMECore

/// Manual integration check against the published release, with optional download verification.
@main struct GitHubUpdateProbe {
    static func main() async throws {
        let service = GitHubUpdateService()
        guard let release = try await service.latest(), release.version == CommandLine.arguments[1],
              release.installer != nil, release.manifest != nil else { throw UpdateError.invalidRelease }
        print("Latest release and installer assets: \(release.version)")
        if CommandLine.arguments.contains("--download") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-UpdateProbe-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = try await service.download(release, to: directory)
            guard FileManager.default.fileExists(atPath: file.path) else { throw UpdateError.integrity }
            print("Release download, platform, size and SHA-256 validation: passed")
        }
    }
}
