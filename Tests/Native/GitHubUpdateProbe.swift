import Foundation
@testable import FluentIMECore

/// Manual integration check against the published release, with optional download verification.
@main struct GitHubUpdateProbe {
    static func main() async throws {
        let edition: ReleaseEdition = CommandLine.arguments.contains("--full") ? .full : .lite
        let config = URLSessionConfiguration.ephemeral
        if CommandLine.arguments.contains("--simulate-api-limit") { config.protocolClasses = [RateLimitedAPI.self] }
        let service = GitHubUpdateService(edition: edition, configuration: config)
        guard let release = try await service.latest(), release.version == CommandLine.arguments[1],
              release.installer(for: edition) != nil, release.manifest(for: edition) != nil else { throw UpdateError.invalidRelease }
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

/// Only the API response is simulated. Redirects, manifests and installers are live.
private final class RateLimitedAPI: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
