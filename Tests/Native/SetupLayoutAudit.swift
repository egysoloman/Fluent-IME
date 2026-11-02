import AppKit
import Carbon
import FluentKit
import FluentIMECore

@main struct SetupLayoutAudit {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // A Mac without the input method registered gets NULL from TIS; setup must not crash on it.
        precondition(InputMethodInstallation.inputSources([kTISPropertyBundleID as String: "org.fluentime.audit.unregistered"]).isEmpty)
        _ = InputMethodInstallation.shared.isEnabled
        final class Installation: SetupInstallation {
            var isInstalled = false, isEnabled = false, hasLocalDictionary = true
            func install(completion: @escaping (Result<Void, Error>) -> Void) { isInstalled = true; completion(.success(())) }
            func enable() throws { isEnabled = true }
            func complete(resetDictionary: Bool, applyPreferences: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) { fatalError("Layout audit must not commit preferences") }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let controller = SetupWindowController(installation: Installation())
            controller.showWindow(nil)
            let root = controller.window!.contentView!
            for step in 0..<5 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
                root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
                for label in all(root).compactMap({ $0 as? FluentSelectableLabel }) where !label.stringValue.isEmpty {
                    let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000))
                    if needed.height > label.bounds.height + 1 { fputs("Clipped text: \(label.stringValue), needed=\(needed.height), actual=\(label.bounds.height)\n", stderr) }
                    precondition(needed.height <= label.bounds.height + 1, "Clipped text: \(label.stringValue), needed=\(needed.height), actual=\(label.bounds.height)")
                    precondition(label.superview!.bounds.contains(label.frame), "Label extends outside its page")
                }
                let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(dark ? "dark" : "light")-step-\(step + 1).png"))
                if step < 4 {
                    let title = step == 0 ? L10n.installAction : step == 1 ? L10n.installEnable : L10n.setupNext
                    all(root).compactMap { $0 as? FluentButton }.first { $0.title == title }!.onClick?()
                }
            }
            controller.window?.orderOut(nil)
        }
        print("Setup layout passed: \(L10n.locale.identifier), 5 steps, light + dark, no text clipping")
    }
}
