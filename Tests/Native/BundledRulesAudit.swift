import AppKit
import FluentIMECore

@main struct BundledRulesAudit {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let old = URL(fileURLWithPath: CommandLine.arguments[2])
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-BundleAudit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: user) }
        func seed() throws {
            let engine = try RimeEngine(sharedDirectory: old, userDirectory: user)
            let input = try InputSession(engine: engine)
            for byte in "nihao".utf8 { input.rime.process(key: Int32(byte)) }
            precondition(input.composition.candidates.first?.text == "你好")
        }
        try seed()
        let installation = user.appendingPathComponent("installation.yaml")
        let oldInstall = try String(contentsOf: installation).replacingOccurrences(of: "0.4.6", with: "0.4.0")
        try oldInstall.write(to: installation, atomically: true, encoding: .utf8)
        let start = Date()
        let engine = try RimeEngine(sharedDirectory: root, userDirectory: user)
        print("Upgrade init seconds: \(Date().timeIntervalSince(start))")
        var options = InputOptions(autoCorrection: false, learning: false)
        let input = try InputSession(engine: engine, options: { options })
        for mask in 0...255 {
            input.cancel(); options.fuzzyPinyinMask = mask; input.applyOptions()
            for byte in "nihao".utf8 { input.rime.process(key: Int32(byte)) }
            precondition(input.composition.candidates.contains { $0.text == "你好" }, "Mask \(mask)")
        }
        input.cancel(); options.fuzzyPinyinMask = 0; input.applyOptions()
        for byte in "shi".utf8 { input.rime.process(key: Int32(byte)) }
        precondition(input.rime.process(key: RimeKey.right))
        precondition(input.composition.highlighted == 1, "Upgrade kept stale arrow bindings")
        print("Bundled rules: 256 masks and upgrade arrow bindings passed")
    }
}
