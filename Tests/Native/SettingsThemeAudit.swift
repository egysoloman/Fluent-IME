import AppKit
import FluentKit
import FluentIMECore
import CRimeBridge

@main struct SettingsThemeAudit {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = try RimeEngine(sharedDirectory: URL(fileURLWithPath: CommandLine.arguments[2]),
            userDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-ThemeAudit-" + UUID().uuidString))
        defer { FIMFinalize() }
        let controller = try SettingsWindowController(engine: engine)
        controller.showWindow(nil)
        let window = controller.window!, root = window.contentView!
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func color(_ value: NSColor?) -> [CGFloat] {
            guard let c = value?.usingColorSpace(.sRGB) else { return [] }
            return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        }
        func name(_ appearance: NSAppearance) -> String { appearance.bestMatch(from: [.aqua, .darkAqua])!.rawValue }
        let search = all(root).compactMap { $0 as? FluentSearchTextField }.first!
        let preview = all(root).compactMap { $0 as? PreviewTextView }.first
        var editor: NSTextView?
        if preview == nil, ProcessInfo.processInfo.environment["THEME_AUDIT_EDIT_SEARCH"] != "0" {
            search.selectText(nil)
            editor = search.currentEditor() as? NSTextView
            editor!.setMarkedText("hua", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: 0))
        }
        if let preview {
            window.makeFirstResponder(preview)
            for (text, code) in [("h", UInt16(4)), ("u", UInt16(32)), ("a", UInt16(0))] {
                preview.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
            }
        }
        let controlWindow = NSWindow(contentRect: NSRect(x: 20, y: 200, width: 300, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        controlWindow.isReleasedWhenClosed = false
        let fields: [NSTextField] = [FluentTextField(placeholder: "Text"), FluentSearchTextField(placeholder: "Search"), FluentSecureTextField(placeholder: "Secure")]
        for (i, field) in fields.enumerated() {
            if let field = field as? FluentTextField { field.theme = FluentTheme() }
            if let field = field as? FluentSearchTextField { field.theme = FluentTheme() }
            if let field = field as? FluentSecureTextField { field.theme = FluentTheme() }
            field.stringValue = "sample"; field.frame = NSRect(x: 20, y: 20 + i * 45, width: 260, height: 32)
            controlWindow.contentView!.addSubview(field)
        }
        controlWindow.orderFront(nil); controlWindow.contentView!.layoutSubtreeIfNeeded()
        var composition = Composition(); composition.rawInput = "hua"; composition.preedit = "hua"; composition.cursorUTF16 = 3
        composition.candidates = ["花", "话", "画", "华", "化"].map { Candidate($0) }
        let candidate = CandidatePanel(), emoji = EmojiPanel()
        var rows: [[String: Any]] = []
        func capture(_ state: String, panels: Bool = false) throws {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
            // Inspect before asking for layout/display, so the probe cannot repair a missed refresh.
            var row: [String: Any] = ["state": state,
                "preference": ProcessInfo.processInfo.environment["FLUENTIME_RENDER_THEME"] ?? "system",
                "appAppearance": name(NSApp.effectiveAppearance), "windowAppearance": name(window.effectiveAppearance),
                "searchInk": color(search.textColor), "editorInk": color(editor?.textColor),
                "searchIdentity": all(root).contains { $0 === search }, "editorIdentity": editor.map { search.currentEditor() === $0 } ?? false,
                "marked": editor?.hasMarkedText() ?? false, "rawFieldInks": fields.map { color($0.textColor) },
                "page": String(describing: Mirror(reflecting: controller).descendant("page")!),
                "materialFills": all(root).compactMap { ($0 as? FluentMaterialView).map { color($0.fallbackColor) } },
                "labels": all(root).compactMap { v -> [String: Any]? in
                    guard let f = v as? NSTextField, !f.isEditable else { return nil }
                    return ["text": f.stringValue, "ink": color(f.textColor)]
                }]
            if let preview {
                row["previewText"] = preview.string; row["previewMarked"] = preview.hasMarkedText()
                row["previewFocused"] = window.firstResponder === preview
                row["previewIdentity"] = all(root).contains { $0 === preview }
            }
            var images: [(String, NSView)] = [("settings", root), ("fields", controlWindow.contentView!)]
            if state.hasPrefix("menu") {
                let menus = (window.childWindows ?? []).filter(\.isVisible)
                row["menus"] = menus.map { menu -> [String: Any] in
                    ["identity": String(describing: ObjectIdentifier(menu)), "appearance": name(menu.effectiveAppearance),
                     "ink": all(menu.contentView!).compactMap { ($0 as? NSTextField).map { color($0.textColor) } }]
                }
                images += menus.enumerated().map { ("menu-\($0.offset)", $0.element.contentView!) }
            }
            if panels {
                row["candidateAppearance"] = name(candidate.candidateView.effectiveAppearance)
                row["emojiAppearance"] = name(emoji.paletteView.effectiveAppearance)
                row["emojiInk"] = color(emoji.paletteView.searchField.textColor)
                row["emojiMaterials"] = all(emoji.paletteView).compactMap { ($0 as? FluentMaterialView).map { color($0.fallbackColor) } }
                row["candidateVisible"] = candidate.isVisible; row["emojiVisible"] = emoji.isVisible
                row["emojiQuery"] = emoji.paletteView.searchField.stringValue
                row["candidateChoices"] = all(candidate.candidateView).filter { String(describing: type(of: $0)) == "CandidateChoice" }.map { String(describing: ObjectIdentifier($0)) }
                row["emojiItems"] = all(emoji.paletteView).filter { String(describing: type(of: $0)) == "SymbolButton" }.map { String(describing: ObjectIdentifier($0)) }
                images += [("candidate", candidate.candidateView), ("emoji", emoji.paletteView)]
            }
            rows.append(row)
            for (label, view) in images where view.bounds.width > 0 && view.bounds.height > 0 {
                view.displayIfNeeded(); CATransaction.flush()
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext; cg.scaleBy(x: 2, y: 2)
                if view.isFlipped { cg.translateBy(x: 0, y: view.bounds.height); cg.scaleBy(x: 1, y: -1) }
                view.layer?.render(in: cg)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(state)-\(label).png"))
            }
        }
        try capture("light")
        NSApp.appearance = NSAppearance(named: .darkAqua); try capture("dark")
        NSApp.appearance = NSAppearance(named: .aqua); try capture("light-again")
        editor?.unmarkText(); search.stringValue = ""
        if let combo = all(root).first(where: { $0.identifier?.rawValue == "FluentKit.ComboBox.NativeBridge" }) as? NSComboBox {
            combo.performClick(nil)
            try capture("menu-light")
            NSApp.appearance = NSAppearance(named: .darkAqua); try capture("menu-dark")
            NSApp.appearance = NSAppearance(named: .aqua); try capture("menu-light-again")
        }
        candidate.present(composition, caret: NSRect(x: 400, y: 500, width: 1, height: 20))
        emoji.present(near: NSRect(x: 800, y: 500, width: 1, height: 20), onInsert: { _ in })
        emoji.paletteView.searchField.stringValue = "smile"
        emoji.paletteView.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try capture("panels-light", panels: true)
        NSApp.appearance = NSAppearance(named: .darkAqua); try capture("panels-dark", panels: true)
        NSApp.appearance = NSAppearance(named: .aqua); try capture("panels-light-again", panels: true)
        candidate.orderOut(nil); emoji.dismiss(); controlWindow.close(); window.close()
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.deletingLastPathComponent().appendingPathComponent("results.json"))
    }
}
