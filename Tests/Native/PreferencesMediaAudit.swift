import AppKit
import FluentKit
import FluentIMECore
import CryptoKit
import CRimeBridge

@main struct PreferencesMediaAudit {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        NSApp.appearance = NSAppearance(named: .aqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.16)) }
        func capture(_ v: NSView, _ name: String) throws {
            v.layoutSubtreeIfNeeded(); pump(); v.displayIfNeeded(); CATransaction.flush()
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext; cg.scaleBy(x: 2, y: 2)
            if v.isFlipped { cg.translateBy(x: 0, y: v.bounds.height); cg.scaleBy(x: 1, y: -1) }
            v.layer?.render(in: cg)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        func button(_ title: String, in root: NSView) -> FluentButton { all(root).compactMap { $0 as? FluentButton }.first { $0.title == title }! }
        let defaults = UserDefaults.standard
        let keys = ["interfaceLanguage", "setupCompleted", "enabledInputModes", "defaultInputMode", "clipboardRecording", "advancedEffects", "fontFamily.zh-Hans", "fontFamily.zh-Hant", "fontFamily.en"]
        for key in keys { defaults.removeObject(forKey: key) }
        defer { for key in keys { defaults.removeObject(forKey: key) } }
        let engine = try RimeEngine(sharedDirectory: URL(fileURLWithPath: CommandLine.arguments[2]), userDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-MediaAudit-" + UUID().uuidString))
        defer { FIMFinalize() }
        final class FakeInstallation: SetupInstallation {
            var isInstalled = false, isEnabled = false, hasLocalDictionary = true
            var finished = false
            func install(completion: @escaping (Result<Void, Error>) -> Void) { isInstalled = true; completion(.success(())) }
            func enable() throws { isEnabled = true }
            func complete(resetDictionary: Bool, applyPreferences: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) { applyPreferences(); finished = true; completion(.success(())) }
        }
        let fake = FakeInstallation()
        let setup = SetupWindowController(installation: fake)
        let window = setup.window!, root = window.contentView!
        setup.showWindow(nil); pump()
        precondition(all(root).compactMap { $0 as? FluentSearchTextField }.isEmpty, "Setup must not have search")
        precondition(!button(L10n.setupNext, in: root).isEnabled)
        try capture(root, "setup-install")
        button(L10n.installAction, in: root).onClick?(); button(L10n.installEnable, in: root).onClick?()
        precondition(button(L10n.setupNext, in: root).isEnabled)
        button(L10n.setupNext, in: root).onClick?()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            func entranceOffset() -> Double? {
                let group = all(root).compactMap { $0.layer?.animation(forKey: "FluentIME.Page.Entrance") as? CAAnimationGroup }.first
                let slide = group?.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform.translation.x" }
                return (slide?.fromValue as? NSNumber)?.doubleValue
            }
            precondition(entranceOffset() == 40, "Setup forward transition missing")
            button(L10n.setupPrevious, in: root).onClick?()
            precondition(entranceOffset() == -40, "Setup backward transition missing")
            button(L10n.setupNext, in: root).onClick?()
        }
        precondition(button(L10n.setupNext, in: root).role == .primary)
        try capture(root, "setup-dictionary")
        button(L10n.setupNext, in: root).onClick?(); pump()
        all(root).compactMap { $0 as? FluentCheckBox }.first!.onValueChanged?(false)
        precondition(Preferences.shared.enabledInputModes == InputMode.allCases, "Wizard changed preferences before Finish")
        try capture(root, "setup-languages")
        button(L10n.setupNext, in: root).onClick?(); try capture(root, "setup-privacy")
        precondition(!Preferences.shared.setupCompleted)
        button(L10n.installFinish, in: root).onClick?(); pump()
        precondition(fake.finished && Preferences.shared.setupCompleted && !Preferences.shared.enabledInputModes.contains(.simplifiedChinese))
        window.orderOut(nil)
        setenv("FLUENTIME_RENDER_PAGE", "home", 1)
        let settings = try SettingsWindowController(engine: engine)
        try settings.render(to: output.appendingPathComponent("settings-home.png"))
        let labels = all(settings.window!.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
        precondition(!labels.contains(InputMode.simplifiedChinese.title), "Disabled language must not have a root entry")
        MaintenanceDialogs.uninstall(in: settings.window!.contentView!)
        try capture(settings.window!.contentView!, "uninstall-dialog")
        settings.window?.orderOut(nil)
        let renderLanguage = ProcessInfo.processInfo.environment["FLUENTIME_RENDER_LANGUAGE"]
        unsetenv("FLUENTIME_RENDER_LANGUAGE")
        setenv("FLUENTIME_RENDER_PAGE", "appearance", 1)
        let languageSettings = try SettingsWindowController(engine: engine)
        let enabledModes = Preferences.shared.enabledInputModes
        for (code, title) in [("en", "Fluent IME Settings"), ("zh-Hant", "Fluent IME 設定"), ("zh-Hans", "Fluent IME 设置")] {
            Preferences.shared.interfaceLanguage = code; pump()
            FileHandle.standardError.write(Data("Language audit requested=\(code) resolved=\(L10n.interfaceLanguage) title=\(languageSettings.window?.title ?? "nil")\n".utf8))
            precondition(L10n.interfaceLanguage == code && languageSettings.window?.title == title, "Interface language did not update")
            let fields = all(languageSettings.window!.contentView!).compactMap { $0 as? FluentSearchTextField }
            FileHandle.standardError.write(Data("Search fields=\(fields.count) plain=\(fields.first?.placeholderString ?? "nil") attributed=\(fields.first?.placeholderAttributedString?.string ?? "nil") expected=\(L10n.settingsSearchPlaceholder)\n".utf8))
            precondition((fields.first?.placeholderAttributedString?.string ?? fields.first?.placeholderString) == L10n.settingsSearchPlaceholder, "Search language did not update")
            precondition(Preferences.shared.enabledInputModes == enabledModes, "Interface language changed input modes")
            try languageSettings.render(to: output.appendingPathComponent("interface-" + code + ".png"))
        }
        languageSettings.window?.orderOut(nil)
        defaults.removeObject(forKey: "interfaceLanguage")
        if let renderLanguage { setenv("FLUENTIME_RENDER_LANGUAGE", renderLanguage, 1) }
        let suite = "FluentIME-language-audit-" + UUID().uuidString
        let languageDefaults = UserDefaults(suiteName: suite)!
        let hans = LanguagePreferences(.simplifiedChinese, defaults: languageDefaults)
        let hant = LanguagePreferences(.traditionalChinese, defaults: languageDefaults)
        hans.autoCorrection = false; hant.englishPunctuation = true
        precondition(!hans.autoCorrection && hant.autoCorrection && !hans.englishPunctuation && hant.englishPunctuation)
        languageDefaults.removePersistentDomain(forName: suite)
        var fontRows: [[String: Any]] = []
        for mode in InputMode.allCases {
            FontPreferences.set(FontPreferences.system, for: mode)
            let actual = FontPreferences.font(size: 15, weight: .regular, language: mode)
            precondition(actual.fontName == NSFont.systemFont(ofSize: 15).fontName)
        }
        let custom = NSFontManager.shared.availableFontFamilies.contains("Microsoft YaHei") ? "Microsoft YaHei" : "Helvetica"
        let fieldWindow = NSWindow(contentRect: NSRect(x: 250, y: 400, width: 440, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        fieldWindow.contentView!.wantsLayer = true
        let field = FluentSearchTextField(placeholder: L10n.settingsSearchPlaceholder); field.frame = NSRect(x: 24, y: 34, width: 392, height: 32)
        fieldWindow.contentView!.addSubview(field); fieldWindow.makeKeyAndOrderFront(nil)
        for (tag, family) in [("system", FontPreferences.system), ("custom", custom)] {
            FontPreferences.set(family, for: FontPreferences.interfaceMode)
            field.theme = Preferences.shared.theme; field.stringValue = ""; fieldWindow.makeFirstResponder(nil)
            try capture(fieldWindow.contentView!, "field-" + tag + "-placeholder")
            field.selectText(nil); let editor = field.currentEditor() as! NSTextView
            try capture(fieldWindow.contentView!, "field-" + tag + "-focused")
            editor.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 0, length: 0))
            precondition(editor.hasMarkedText()); try capture(fieldWindow.contentView!, "field-" + tag + "-composition")
            editor.insertText("你好", replacementRange: editor.markedRange())
            precondition(!editor.hasMarkedText() && editor.string == "你好")
            let selection = NSRange(location: 0, length: 1); editor.setSelectedRange(selection)
            for effects in [false, true] {
                Preferences.shared.advancedEffects = effects
                field.theme = Preferences.shared.theme
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 100, y: 50), modifierFlags: [], timestamp: 0, windowNumber: fieldWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                field.rightMouseDown(with: event); pump()
                let menus = (fieldWindow.childWindows ?? []).filter(\.isVisible)
                precondition(!menus.isEmpty, "Editing menu did not open")
                let menu = menus.last!, identity = ObjectIdentifier(menu)
                let materials = all(menu.contentView!).compactMap { $0 as? FluentMaterialView }
                precondition(materials.contains { $0.isMaterialEnabled == effects })
                try capture(menu.contentView!, "menu-\(tag)-\(effects ? "acrylic" : "solid")-light")
                NSApp.appearance = NSAppearance(named: .darkAqua); field.theme = Preferences.shared.theme; pump()
                precondition((fieldWindow.childWindows ?? []).contains { ObjectIdentifier($0) == identity && $0.isVisible })
                precondition(field.currentEditor() === editor && editor.selectedRange() == selection)
                try capture(menu.contentView!, "menu-\(tag)-\(effects ? "acrylic" : "solid")-dark")
                for child in fieldWindow.childWindows ?? [] { child.orderOut(nil) }
                // Escape dismisses the retained Fluent menu presenter before the next trial.
                menu.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: menu.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
                NSApp.appearance = NSAppearance(named: .aqua)
            }
            fieldWindow.makeFirstResponder(nil); try capture(fieldWindow.contentView!, "field-" + tag + "-committed")
            field.selectText(nil)
            let pasteEditor = field.currentEditor() as! NSTextView
            let pasteboard = NSPasteboard(name: .init("FluentIME-PasteAudit-" + UUID().uuidString))
            pasteboard.setString("first\nsecond", forType: .string)
            pasteEditor.selectAll(nil); pasteEditor.breakUndoCoalescing()
            let undo = pasteEditor.undoManager!
            undo.removeAllActions(); undo.beginUndoGrouping()
            _ = pasteEditor.readSelection(from: pasteboard)
            undo.endUndoGrouping(); pump()
            precondition(pasteEditor.string == "first second", "Single-line paste did not normalize")
            precondition(undo.canUndo); undo.undo(); precondition(pasteEditor.string == "你好")
            undo.redo(); precondition(pasteEditor.string == "first second")
            pasteEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            precondition(!field.stringValue.contains("\n"))
            pasteboard.releaseGlobally()
            fontRows.append(["setting": family, "font": field.font?.fontName ?? "nil", "size": field.font?.pointSize ?? 0])
        }
        FontPreferences.set("Monaco", for: .english)
        let mixed = IMEFont.attributed("你好 abc", size: 15, language: .simplifiedChinese, color: .black)
        precondition((mixed.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.familyName == "Monaco")
        defaults.set("FluentIME Missing Font", forKey: "fontFamily.zh-Hant")
        precondition(FontPreferences.selected(.traditionalChinese) == FontPreferences.system)
        let selectable = FluentSelectableLabel(wrappingLabelWithString: "词库和自学习")
        selectable.frame = NSRect(x: 24, y: 0, width: 300, height: 30); fieldWindow.contentView!.addSubview(selectable)
        selectable.selectText(nil)
        let labelEditor = selectable.currentEditor() as! NSTextView
        let labelSelection = NSRange(location: 0, length: 2); labelEditor.setSelectedRange(labelSelection)
        let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: selectable.convert(NSPoint(x: 15, y: 12), to: nil), modifierFlags: [], timestamp: 0, windowNumber: fieldWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        selectable.rightMouseDown(with: contextEvent); pump()
        let labelMenu = (fieldWindow.childWindows ?? []).last(where: { $0.isVisible })!
        precondition(all(labelMenu.contentView!).contains { $0 is FluentMaterialView }, "Selectable labels must use Fluent menus")
        precondition(selectable.currentEditor() === labelEditor && labelEditor.selectedRange() == labelSelection)
        try capture(labelMenu.contentView!, "label-context-menu")
        labelMenu.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: labelMenu.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        fieldWindow.orderOut(nil)
        for mode in InputMode.allCases { FontPreferences.set(FontPreferences.system, for: mode) }
        Preferences.shared.advancedEffects = false
        let board = NSPasteboard(name: .init("FluentIME-MediaAudit-" + UUID().uuidString)); defer { board.releaseGlobally() }
        let key = SymmetricKey(size: .bits256), dir = output.appendingPathComponent("temporary-vault")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, storage: ClipboardVault(directory: dir, key: { _ in key }))
        history.setRecording(true)
        let image = NSImage(size: NSSize(width: 320, height: 150), flipped: false) { rect in
            NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            ("Fluent IME" as NSString).draw(at: NSPoint(x: 24, y: 62), withAttributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.white]); return true
        }
        board.clearContents(); board.setData(image.tiffRepresentation!, forType: .tiff); history.poll()
        try history.setPinned(history.entries[0].id, true)
        board.clearContents(); board.setString("Windows 11 就在此处！\n使用系统字体，保留自己的输入习惯。", forType: .string); history.poll()
        board.clearContents(); board.setString("file:///tmp/Example.pdf", forType: .fileURL); history.poll()
        let palette = EmojiPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 400), clipboard: history)
        let panel = NSPanel(contentRect: NSRect(x: 500, y: 400, width: 360, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = palette; panel.orderFront(nil); palette.prepare(); palette.selectTab(5)
        try capture(palette, "clipboard")
        precondition(all(palette).compactMap { $0 as? ClipboardCard }.count == 3)
        let card = all(palette).compactMap { $0 as? ClipboardCard }.first!
        let originalID = history.entries.first { $0.isPinned }!.id
        card.onPin?(); precondition(history.entries.first { $0.id == originalID }?.isPinned == false)
        try history.setPinned(originalID, true)
        let restored = ClipboardHistory(pasteboard: board, automaticPolling: false, storage: ClipboardVault(directory: dir, key: { _ in key }))
        precondition(restored.entries.count == 1 && restored.entries[0].kind == .image)
        button(L10n.clipboardClear, in: palette).onClick?(); precondition(history.entries.isEmpty)
        let cleared = try ClipboardVault(directory: dir, key: { _ in key }).load(); precondition(cleared.isEmpty)
        try capture(palette, "clipboard-cleared"); panel.orderOut(nil)
        for page in ["fonts", "clipboard", "models"] {
            setenv("FLUENTIME_RENDER_PAGE", page, 1)
            let controller = try SettingsWindowController(engine: engine)
            try controller.render(to: output.appendingPathComponent("settings-" + page + ".png"))
            controller.window?.orderOut(nil)
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "fontStates": fontRows, "wizardDraftIsolation": true, "clipboardCardsPinRestoreClear": true, "editingMenuThemeAndSelection": true, "singleLinePasteUndoRedoReturn": true], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("validation.json"))
        print("Preferences, clipboard, fonts and editing-menu audit passed")
    }
}
