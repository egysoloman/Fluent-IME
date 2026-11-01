import AppKit
import FluentKit
import FluentIMECore

/// Preserve native multiline selection while routing its context menu through FluentKit.
final class FluentSelectableLabel: NSTextField {
    var theme = Preferences.shared.theme { didSet { flyout?.update(items: commands(), theme: theme) } }
    private var monitor: Any?
    private var flyout: FluentMenuFlyout?
    private var selectedText = ""
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isSelectable = true; isEditable = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            self.presentMenu(event); return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override func rightMouseDown(with event: NSEvent) { presentMenu(event) }
    private func commands() -> [FluentMenuItem] {
        [FluentMenuItem(id: "copy", L10n.menuCopy, keyEquivalent: "c") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.selectedText, forType: .string)
        }, FluentMenuItem(id: "selectAll", L10n.menuSelectAll, keyEquivalent: "a") { [weak self] in self?.selectText(nil) }]
    }
    private func presentMenu(_ event: NSEvent) {
        selectedText = stringValue
        if let editor = currentEditor() as? NSTextView {
            let range = editor.selectedRange(), text = editor.string as NSString
            if range.length > 0, NSMaxRange(range) <= text.length { selectedText = text.substring(with: range) }
        }
        flyout = FluentMenuFlyout(items: commands(), theme: theme, matchesAnchorWidth: false)
        flyout?.present(relativeTo: self, at: convert(event.locationInWindow, from: nil))
    }
}
