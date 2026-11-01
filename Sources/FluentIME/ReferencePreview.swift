import AppKit
import FluentIMECore

/// Snapshots of the actual native presenters with live Rime data, not a separate mockup.
func renderReferenceComponents(to directory: URL, engine: RimeEngine) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = try InputSession(engine: engine, options: { var value = Preferences.shared.inputOptions; value.learning = false; value.startsInEnglish = false; return value })
    let session = input.rime
    for character in "she".utf8 { session.process(key: Int32(character)) }
    print("she candidates: \(input.composition.candidates.map(\.text).joined(separator: " | "))")
    func save(_ view: NSView, name: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.backgroundColor = Preferences.shared.theme.windowBackground
        window.displayIfNeeded(); view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let export = bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
        try export.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
    let bar = CandidateView(frame: .zero)
    bar.update(input.composition)
    let background = IMEFlippedView(frame: NSRect(x: 0, y: 0, width: bar.preferredSize.width + CandidateChrome.sideMargin * 2, height: bar.preferredSize.height + 23 + CandidateChrome.bottomMargin))
    background.wantsLayer = true
    background.layer?.backgroundColor = (Preferences.shared.theme.isDark ? Preferences.shared.theme.windowBackground : NSColor(srgbRed: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    let preedit = NSTextField(labelWithString: input.composition.preedit)
    let preeditFont = IMEFont.font(ofSize: 14.5)
    preedit.attributedStringValue = NSAttributedString(string: input.composition.preedit, attributes: [.font: preeditFont, .foregroundColor: Preferences.shared.theme.textPrimary, .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue])
    preedit.frame = NSRect(x: CandidateChrome.sideMargin - 3, y: 2, width: 200, height: 22); background.addSubview(preedit)
    let caret = NSView(frame: NSRect(x: CandidateChrome.sideMargin - 1 + (input.composition.preedit as NSString).size(withAttributes: [.font: preeditFont]).width, y: 4.5, width: 0.5, height: 18))
    caret.wantsLayer = true; caret.layer?.backgroundColor = Preferences.shared.theme.textPrimary.cgColor; background.addSubview(caret)
    bar.frame = NSRect(origin: NSPoint(x: CandidateChrome.sideMargin, y: 23), size: bar.preferredSize)
    let shadow = CandidateShadowView(frame: CandidateChrome.shadowFrame(around: bar.frame, flipped: true))
    background.addSubview(shadow); background.addSubview(bar)
    try save(background, name: "candidate-bar.png")
    let palette = EmojiPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
    try save(palette, name: "emoji-panel.png")
    if ProcessInfo.processInfo.environment["FLUENTIME_VALIDATE_POPUP"] == "1" {
        try validateCandidatePopup(input.composition)
    }
}

/// Opt-in native-window smoke check for the paired popup's placement and lifecycle.
private func validateCandidatePopup(_ composition: Composition) throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "FluentIME.PopupValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    try require(NSScreen.main != nil, "No screen for popup validation")
    let screen = NSScreen.main!
    let panel = CandidatePanel()
    defer { panel.orderOut(nil) }
    let keyWindow = NSApp.keyWindow
    let caret = NSRect(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.midY, width: 1, height: 20)
    for _ in 0..<2 {
        panel.present(composition, caret: caret)
        let shadowWindows = panel.childWindows?.compactMap { $0 as? CandidateShadowPanel } ?? []
        try require(shadowWindows.count == 1, "Expected one shadow window; children: \(String(describing: panel.childWindows)), composing: \(composition.isComposing)")
        let shadow = shadowWindows[0]
        try require(panel.isVisible && shadow.isVisible, "Popup and shadow must appear together")
        try require(!panel.hasShadow && !shadow.hasShadow && shadow.ignoresMouseEvents, "Unexpected native shadow or mouse interception")
        try require(!panel.canBecomeKey && !shadow.canBecomeKey && NSApp.keyWindow === keyWindow, "Popup stole focus")
        let surface = shadow.convertToScreen(NSRect(x: CandidateChrome.sideMargin, y: CandidateChrome.bottomMargin, width: panel.frame.width, height: panel.frame.height))
        try require(surface == panel.frame, "Shadow moved relative to the candidate face")
        panel.present(Composition(), caret: caret)
        try require(!panel.isVisible && !shadow.isVisible, "Ending composition left an orphan shadow")
    }
    print("Native popup: placement, click-through shadow, nonactivation, hide/reopen verified.")
}
