import AppKit
import InputMethodKit
import FluentKit
import FluentIMECore

@main struct CandidatePopupAudit {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.finishLaunching()
        let oldExpansionEnabled = UserDefaults.standard.object(forKey: "candidateExpansionEnabled")
        Preferences.shared.candidateExpansionEnabled = true
        defer {
            if let oldExpansionEnabled { UserDefaults.standard.set(oldExpansionEnabled, forKey: "candidateExpansionEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "candidateExpansionEnabled") }
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let screen = NSScreen.main!.visibleFrame
        let panel = CandidatePanel()
        precondition(panel.level.rawValue > NSWindow.Level.screenSaver.rawValue)
        let emoji = EmojiPanel()
        precondition(emoji.level.rawValue > panel.level.rawValue)
        let savedIndicator = Preferences.shared.showInputModeIndicator
        let savedEffects = Preferences.shared.advancedEffects
        let savedModes = Preferences.shared.enabledInputModes
        defer {
            Preferences.shared.showInputModeIndicator = savedIndicator
            Preferences.shared.advancedEffects = savedEffects
            Preferences.shared.enabledInputModes = savedModes
        }
        defer { panel.orderOut(nil) }
        var composition = Composition()
        composition.rawInput = "fa'ka"; composition.preedit = "fa'ka"
        composition.candidates = ["发卡", "打卡", "罚款", "发快递", "反馈", "发现", "发开"].map { Candidate($0) }
        var rows: [[String: Any]] = []
        func rect(_ r: NSRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
        func serverRect(_ window: NSWindow?) -> NSRect {
            guard let window,
                  let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
                  let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return .zero }
            return NSRect(x: frame.minX, y: NSScreen.screens[0].frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        }
        func record(_ state: String) {
            let shadow = panel.childWindows?.compactMap { $0 as? CandidateShadowPanel }.first
            let view = shadow?.shadowView
            let face = view.map { NSRect(x: CandidateChrome.sideMargin, y: CandidateChrome.topMargin,
                width: $0.bounds.width - CandidateChrome.sideMargin * 2,
                height: $0.bounds.height - CandidateChrome.topMargin - CandidateChrome.bottomMargin) } ?? .zero
            let shadowFace = shadow.flatMap { s in view.map { s.convertToScreen($0.convert(face, to: nil)) } } ?? .zero
            rows.append(["state": state, "visible": panel.isVisible, "body": rect(panel.frame),
                "shadow": rect(shadow?.frame ?? .zero), "shadowView": rect(view?.frame ?? .zero),
                "shadowFace": rect(shadowFace), "errorX": shadowFace.minX - panel.frame.minX,
                "errorY": shadowFace.minY - panel.frame.minY, "errorW": shadowFace.width - panel.frame.width,
                "errorH": shadowFace.height - panel.frame.height,
                "visibleShadows": panel.childWindows?.filter(\.isVisible).count ?? 0,
                "dark": IMEThemeObservation.current.isDark, "shadowDark": view?.theme.isDark ?? false,
                "shadowPassesMouse": shadow?.ignoresMouseEvents ?? false])
            rows[rows.count - 1]["serverBody"] = rect(serverRect(panel))
            rows[rows.count - 1]["serverShadow"] = rect(serverRect(shadow))
            rows[rows.count - 1]["bodyAlpha"] = panel.alphaValue
            rows[rows.count - 1]["shadowAlpha"] = shadow?.alphaValue ?? 1
            let bodyOnScreen = serverRect(panel), shadowOnScreen = serverRect(shadow)
            rows[rows.count - 1]["serverError"] = [shadowOnScreen.minX + CandidateChrome.sideMargin - bodyOnScreen.minX,
                shadowOnScreen.minY + CandidateChrome.bottomMargin - bodyOnScreen.minY,
                shadowOnScreen.width - CandidateChrome.sideMargin * 2 - bodyOnScreen.width,
                shadowOnScreen.height - CandidateChrome.topMargin - CandidateChrome.bottomMargin - bodyOnScreen.height]
        }
        func settle(_ state: String) {
            record(state + "-immediate")
            let deadline = Date(timeIntervalSinceNow: 0.18)
            while Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                NSApp.updateWindows()
            }
            record(state + "-settled")
        }
        for (index, offset) in [CGFloat(0), 27.5, 55, 0, -90, 300, 450, 0].enumerated() {
            if index == 2 { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if index == 5 { NSApp.appearance = NSAppearance(named: .aqua) }
            if index == 3 { composition.candidates = (0..<7).map { Candidate("较长候选词\($0)") } }
            if index == 6 { composition.candidates = (0..<7).map { Candidate("字\($0)") } }
            let caret = NSRect(x: screen.midX - 200 + offset, y: screen.midY + (index % 2 == 0 ? 0 : 35), width: 1, height: 20)
            panel.present(composition, caret: caret)
            settle("update-\(index)")
        }
        for index in 0..<3 {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 30, y: panel.frame.minY + 10))
            settle("native-move-\(index)")
        }
        panel.orderOut(nil)
        record("dismiss")
        panel.present(composition, caret: NSRect(x: screen.midX, y: screen.midY, width: 1, height: 20))
        settle("reopen")
        // Verify actual WindowServer ordering above a floating overlay, including
        // an already-visible candidate window refreshed after that overlay opens.
        let overlay = NSPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false; overlay.level = .screenSaver
        overlay.orderFrontRegardless()
        panel.present(composition, caret: NSRect(x: screen.midX, y: screen.midY, width: 1, height: 20))
        settle("above-overlay")
        let ordered = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
        let windowNumbers = ordered.compactMap { $0[kCGWindowNumber as String] as? Int }
        precondition(windowNumbers.firstIndex(of: panel.windowNumber)! < windowNumbers.firstIndex(of: overlay.windowNumber)!)
        overlay.orderOut(nil)
        print("IME window levels and WindowServer stacking above floating overlay passed")
        Preferences.shared.advancedEffects = true
        let acrylic = panel.candidateView.subviews.compactMap { $0 as? FluentMaterialView }.first!
        precondition(!acrylic.isHidden && acrylic.isMaterialEnabled && acrylic.materialStyle == .nativeAcrylic)
        precondition(emoji.paletteView.subviews.compactMap { $0 as? FluentMaterialView }.first!.isMaterialEnabled)
        Preferences.shared.advancedEffects = false
        precondition(acrylic.isHidden && !acrylic.isMaterialEnabled)
        Preferences.shared.showInputModeIndicator = true
        Preferences.shared.enabledInputModes = InputMode.allCases
        let badge = InputModePanel()
        var selectedMode: InputMode?
        badge.present(mode: .simplifiedChinese, modes: InputMode.allCases,
                      near: NSRect(x: screen.midX, y: screen.midY, width: 1, height: 20)) { selectedMode = $0 }
        precondition(badge.isVisible && !badge.expanded && !badge.isKeyWindow)
        pump(0.2)
        let badgeAnchor = NSRect(x: screen.midX, y: screen.midY, width: 1, height: 20)
        var oldMode: InputMode = .simplifiedChinese
        for enabled in [InputMode.allCases, [.simplifiedChinese, .english]] {
            let sequence: [InputMode] = enabled.count == 3
                ? [.traditionalChinese, .english, .simplifiedChinese, .english, .traditionalChinese, .simplifiedChinese, .english]
                : [.simplifiedChinese, .english]
            for target in sequence {
                let oldFrame = badge.frame
                badge.present(mode: target, modes: enabled, near: badgeAnchor) { selectedMode = $0 }
                precondition(badge.frame == oldFrame, "Changing modes must keep the collapsed badge anchored")
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let button = badge.contentView!.subviews.compactMap { $0 as? FluentButton }.first!
                    let group = button.layer?.animation(forKey: "FluentIME.Page.Entrance") as? CAAnimationGroup
                    let slide = group?.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform.translation.x" }
                    let expected: Double = enabled.firstIndex(of: target)! < enabled.firstIndex(of: oldMode)! ? -24 : 24
                    precondition((slide?.fromValue as? NSNumber)?.doubleValue == expected, "Badge slide must follow the visible option order")
                }
                oldMode = target; pump(0.2)
            }
        }
        // Restore all three options before checking the expanded selector.
        badge.present(mode: .english, modes: InputMode.allCases, near: badgeAnchor) { selectedMode = $0 }
        badge.contentView!.subviews.compactMap { $0 as? NSButton }.first!.performClick(nil)
        precondition(badge.expanded)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(badge.frame.width == 38, "Expansion must begin at the badge width")
            pump(0.06)
            precondition(badge.frame.width > 38 && badge.frame.width < 134, "Expansion must have intermediate window geometry")
        }
        pump(0.3)
        precondition(badge.frame.width == 134)
        let modeControl = badge.contentView!.subviews.compactMap { $0 as? NSSegmentedControl }.first!
        precondition(modeControl.segmentCount == 3)
        let indicator = modeControl.subviews.first { $0.identifier?.rawValue == "FluentKit.Segmented.SelectionIndicator" }!
        for target in [InputMode.simplifiedChinese, .traditionalChinese, .english] {
            let oldX = indicator.layer!.position.x
            badge.present(mode: target, modes: InputMode.allCases, near: badgeAnchor) { selectedMode = $0 }
            precondition(badge.contentView!.subviews.contains { $0 === modeControl })
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let group = indicator.layer?.animation(forKey: "fluent.segmented.selection") as? CAAnimationGroup
                let slide = group?.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "position" }
                precondition(abs(((slide?.fromValue as? NSValue)?.pointValue.x ?? -1000) - oldX) < 0.5)
                precondition((slide?.toValue as? NSValue)?.pointValue.x == indicator.layer!.position.x)
            }
            pump(0.2)
        }
        let commandItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        commandItem.representedObject = InputMode.traditionalChinese.rawValue
        precondition(InputMethodMenuCommand([kIMKCommandMenuItemName: commandItem] as NSDictionary).mode == .traditionalChinese)
        precondition(InputMethodMenuCommand(commandItem).mode == .traditionalChinese)
        precondition(badge.contentView!.layer?.cornerRadius == 8)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let view = badge.contentView!
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("mode-picker-" + appearance.rawValue + ".png"))
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        modeControl.selectedSegment = 1
        modeControl.sendAction(modeControl.action, to: modeControl.target)
        precondition(selectedMode == .traditionalChinese && badge.isVisible)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(indicator.layer?.animation(forKey: "fluent.segmented.selection") != nil, "FluentKit selection animation missing")
        }
        // A fresh presentation updates the existing selector, rather than flashing a new badge.
        badge.present(mode: .traditionalChinese, modes: InputMode.allCases, near: panel.frame) { selectedMode = $0 }
        precondition(badge.expanded && badge.contentView!.subviews.contains { $0 === modeControl })
        badge.dismiss(); pump(0.25); precondition(!badge.isVisible)
        Preferences.shared.showInputModeIndicator = false
        badge.present(mode: .english, modes: [.english], near: panel.frame) { _ in }
        precondition(!badge.isVisible)
        print("Acrylic toggle and optional nonactivating three-mode indicator passed")
        // Continuous expansion: numbering follows the active row, or the first
        // visible row after the active row has been scrolled offscreen, and
        // appending another batch must preserve the user's scroll position.
        let oldExpansion = UserDefaults.standard.object(forKey: "expandedCandidates")
        defer { if let oldExpansion { UserDefaults.standard.set(oldExpansion, forKey: "expandedCandidates") } else { UserDefaults.standard.removeObject(forKey: "expandedCandidates") } }
        Preferences.shared.expandedCandidates = true
        composition.candidates = (0..<128).map { Candidate("字\($0)") }
        composition.isContinuous = true; composition.highlighted = 0
        var visibleStart = -1, visibleColumns = -1, clicked = -1
        panel.candidateView.onViewportChanged = { visibleStart = $0; visibleColumns = $1 }
        panel.candidateView.onSelect = { clicked = $0 }
        let caret = NSRect(x: screen.midX - 220, y: screen.midY + 90, width: 1, height: 20)
        panel.present(composition, caret: caret); settle("continuous-open")
        let strip = panel.candidateView.subviews.compactMap { $0 as? NSScrollView }.first!
        precondition(strip.documentView!.subviews.count == 128 && strip.hasVerticalScroller)
        precondition(visibleColumns == 6)
        composition.highlighted = 8
        panel.present(composition, caret: caret); settle("continuous-next-row")
        let activeRow = strip.documentView!.subviews.compactMap { $0 as? CandidateChoice }.filter { $0.number > 0 }
        precondition(visibleStart == 6 && activeRow.map(\.number) == [1,2,3,4,5,6])
        precondition(activeRow[2].selected)
        let rowBitmap = panel.candidateView.bitmapImageRepForCachingDisplay(in: panel.candidateView.bounds)!
        panel.candidateView.cacheDisplay(in: panel.candidateView.bounds, to: rowBitmap)
        try rowBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("continuous-active-row.png"))
        composition.highlighted = 0
        panel.present(composition, caret: caret); settle("continuous-first-row")
        strip.contentView.scroll(to: NSPoint(x: 0, y: 280)); strip.reflectScrolledClipView(strip.contentView)
        settle("continuous-scroll")
        precondition(visibleStart == 60)
        let numbered = strip.documentView!.subviews.compactMap { $0 as? CandidateChoice }.filter { $0.number > 0 }
        precondition(numbered.map(\.number) == [1,2,3,4,5,6])
        numbered[1].performClick(nil); precondition(clicked == 61)
        let previousOffset = strip.contentView.bounds.minY
        composition.candidates += (128..<192).map { Candidate("字\($0)") }
        panel.present(composition, caret: caret); settle("continuous-append")
        precondition(strip.contentView.bounds.minY == previousOffset)
        precondition(strip.documentView!.subviews.count == 192)
        composition.highlighted = 150
        panel.present(composition, caret: caret); settle("continuous-keyboard-reveal")
        let selected = strip.documentView!.subviews.compactMap { $0 as? CandidateChoice }.first(where: \.selected)!
        precondition(strip.contentView.bounds.contains(selected.frame))
        precondition(visibleStart == 150 && selected.number == 1)
        Preferences.shared.expandedCandidates = false
        composition.candidates = Array(composition.candidates.prefix(7)); composition.highlighted = 0; composition.isContinuous = false
        panel.present(composition, caret: caret); settle("continuous-collapse")
        print("Continuous grid: 192 items, scroll numbering, selection, append position and keyboard reveal passed")
        let oldPageMotion = UserDefaults.standard.object(forKey: "candidatePageAnimation")
        let oldExpansionMotion = UserDefaults.standard.object(forKey: "candidateExpansionAnimation")
        defer {
            for (key, value) in [("candidatePageAnimation", oldPageMotion), ("candidateExpansionAnimation", oldExpansionMotion)] {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        func pump(_ seconds: Double) {
            let end = Date(timeIntervalSinceNow: seconds)
            while Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.003)); NSApp.updateWindows() }
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Preferences.shared.candidatePageAnimation = true
            composition.page += 1
            panel.present(composition, caret: caret); pump(0.02)
            precondition(strip.documentView!.layer?.animation(forKey: "FluentIME.Page.Entrance") != nil, "Page animation must start after layout")
            panel.present(composition, caret: caret)
            precondition(strip.documentView!.layer?.animation(forKey: "FluentIME.Page.Entrance") != nil, "Identical positioning update must not cancel page animation")
            pump(0.2)
            Preferences.shared.candidatePageAnimation = false
            composition.page += 1
            panel.present(composition, caret: caret); pump(0.02)
            precondition(strip.documentView!.layer?.animation(forKey: "FluentIME.Page.Entrance") == nil)
            Preferences.shared.candidateExpansionAnimation = true
            Preferences.shared.expandedCandidates = true
            composition.candidates = (0..<128).map { Candidate("字\($0)") }; composition.isContinuous = true
            let startHeight = panel.frame.height
            panel.present(composition, caret: caret); panel.present(composition, caret: caret); pump(0.035)
            precondition(panel.frame.height > startHeight && panel.frame.height < panel.candidateView.preferredSize.height)
            record("expansion-midway"); pump(0.2); record("expansion-settled")
            Preferences.shared.expandedCandidates = false
            composition.candidates = Array(composition.candidates.prefix(7)); composition.isContinuous = false
            panel.present(composition, caret: caret); pump(0.035)
            precondition(panel.frame.height > panel.candidateView.preferredSize.height)
            record("collapse-midway"); pump(0.2); record("collapse-settled")
        }
        print("Independent page/expansion motion and repeated presentation passed")
        let expansionButton = panel.candidateView.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == L10n.candidateExpand }!
        let widthWithExpansion = panel.candidateView.preferredSize.width
        precondition(!expansionButton.isHidden)
        Preferences.shared.candidateExpansionEnabled = false
        panel.present(composition, caret: caret); settle("expansion-disabled")
        precondition(expansionButton.isHidden && !Preferences.shared.expandedCandidates)
        precondition(panel.candidateView.preferredSize.width < widthWithExpansion)
        Preferences.shared.candidateExpansionEnabled = true
        panel.present(composition, caret: caret); settle("expansion-enabled")
        precondition(!expansionButton.isHidden && !Preferences.shared.expandedCandidates)
        Preferences.shared.expandedCandidates = true
        Preferences.shared.candidateExpansionEnabled = false
        precondition(!Preferences.shared.expandedCandidates && !Preferences.shared.inputOptions.expandedCandidates)
        print("Expansion feature hides its icon, removes toolbar space and collapses when disabled")
        // Zhuyin composes inline: the popup stays hidden until ↓ (or Space) opens the list.
        // Rime has one engine per process, so this engine is released before the preview's.
        do {
            let shared = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/zhuyin/Fluent Zhuyin.app/Contents/Resources/Rime")
            let engine = try RimeEngine(sharedDirectory: shared, userDirectory: output.appendingPathComponent("zhuyin-user"))
            let options = InputOptions(learning: false, defaultMode: .traditionalChinese)
            let zhuyin = try InputSession(engine: engine, keyboard: .zhuyin, options: { options })
            func key(_ characters: String, _ code: UInt16 = 0) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                 characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            }
            for character in "su3cl3" { _ = zhuyin.handle(key(String(character))) }
            var typed = zhuyin.composition
            precondition(typed.preedit == "你好" && typed.candidates.isEmpty, "Zhuyin converts inline with the list hidden")
            panel.present(typed, caret: caret)
            precondition(!panel.isVisible, "The popup stays hidden while Zhuyin is typed")
            _ = zhuyin.handle(key("", 125)); typed = zhuyin.composition
            precondition(typed.candidates.first?.text == "你好", "↓ opens the list")
            panel.present(typed, caret: caret); settle("zhuyin-list-open")
            precondition(panel.isVisible)
            panel.orderOut(nil)
            print("Zhuyin keeps the popup hidden while typing and shows it once the list opens")
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let shared = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/Fluent IME.app/Contents/Resources/Rime")
            let engine = try RimeEngine(sharedDirectory: shared, userDirectory: output.appendingPathComponent("preview-user"))
            Preferences.shared.candidateExpansionEnabled = true
            Preferences.shared.expandedCandidates = false
            let preview = try SettingsWindowController(engine: engine)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let all = descendants(preview.window!.contentView!)
            let face = all.compactMap { $0 as? CandidateView }.first!
            let shadow = all.compactMap { $0 as? CandidateShadowView }.first!
            let collapsedHeight = face.frame.height
            Preferences.shared.expandedCandidates = true; pump(0.035)
            precondition(face.frame.height > collapsedHeight && face.frame.height < face.preferredSize.height)
            precondition(shadow.frame == CandidateChrome.shadowFrame(around: face.frame, flipped: true))
            pump(0.2)
            Preferences.shared.expandedCandidates = false; pump(0.035)
            precondition(face.frame.height > collapsedHeight)
            precondition(shadow.frame == CandidateChrome.shadowFrame(around: face.frame, flipped: true))
            pump(0.2); precondition(face.frame.height == collapsedHeight)
            Preferences.shared.expandedCandidates = true; pump(0.2)
            face.onSelect?(0); pump(0.2)
            precondition(!Preferences.shared.expandedCandidates && face.frame.height == collapsedHeight)
            Preferences.shared.showInputModeIndicator = true
            preview.showWindow(nil)
            let language = all.compactMap { $0 as? FluentButton }.first { $0.title == L10n.modeSwitchTo(InputMode.traditionalChinese.title) }!
            language.performClick(nil); pump(0.03)
            let visibleModePanels = NSApp.windows.compactMap { $0 as? InputModePanel }.filter(\.isVisible)
            precondition(!visibleModePanels.isEmpty, "Try-input mode indicator must use actual text-view caret geometry")
            visibleModePanels.forEach { $0.dismiss() }
            preview.close()
            print("Try-input expansion/collapse animation shares geometry with its shadow")
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("geometry.json"))
        let failures = rows.filter { row in
            guard row["visible"] as? Bool == true else { return (row["visibleShadows"] as? Int ?? 0) != 0 }
            return ["errorX", "errorY", "errorW", "errorH"].contains { abs(row[$0] as? CGFloat ?? 999) > 0.01 }
                || row["visibleShadows"] as? Int != 1 || row["shadowPassesMouse"] as? Bool != true
                || row["dark"] as? Bool != row["shadowDark"] as? Bool
                || abs((row["bodyAlpha"] as? CGFloat ?? -1) - (row["shadowAlpha"] as? CGFloat ?? -2)) > 0.001
                || ((!Preferences.shared.candidatePopupAnimation || (row["state"] as? String)?.hasSuffix("settled") == true) && row["bodyAlpha"] as? CGFloat != 1)
                || ((row["state"] as? String)?.hasSuffix("settled") == true && (row["serverError"] as? [CGFloat] ?? [999]).contains { abs($0) > 0.01 })
        }
        for row in failures { print(row) }
        print("Candidate popup: \(rows.count) states, \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }
}
