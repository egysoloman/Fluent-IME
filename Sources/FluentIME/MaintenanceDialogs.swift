import AppKit
import FluentKit
import FluentIMECore

enum MaintenanceDialogs {
    static func present(in root: NSView, title: String, message: String, primary: String,
                        checkbox: String? = nil, emphasizePrimary: Bool = false, accepted: @escaping (Bool) throws -> Void) {
        var visible = true, keep = true
        let content = IMEFlippedView(frame: NSRect(x: 0, y: 0, width: 380, height: checkbox == nil ? 110 : 190))
        let description = FluentSelectableLabel(wrappingLabelWithString: message)
        description.font = IMEFont.font(ofSize: 14); description.textColor = Preferences.shared.theme.textPrimary
        description.frame = NSRect(x: 0, y: 0, width: 380, height: 108); content.addSubview(description)
        if let checkbox {
            let check = FluentCheckBox(title: checkbox, isChecked: true); check.theme = Preferences.shared.theme
            check.frame = NSRect(x: 0, y: 132, width: 380, height: 44); check.onValueChanged = { keep = $0 }; content.addSubview(check)
        }
        weak var mounted: NSView?
        let dialog = FluentContentDialog(isPresented: FluentBinding(get: { visible }, set: { visible = $0 }),
            configuration: .init(title: title, primaryButtonText: primary, closeButtonText: L10n.commonCancel, defaultButton: emphasizePrimary ? .primary : .close),
            onClosed: { result in
                mounted?.removeFromSuperview()
                guard result == .primary else { return }
                do { try accepted(keep) }
                catch { showError(error, in: root) }
            }, content: { FluentEmptyView() }, dialogContent: { FluentNativeView(content).frame(width: 380, height: checkbox == nil ? 110 : 190) })
        let host = dialog._makeView(in: FluentRenderContext(theme: Preferences.shared.theme, locale: L10n.locale))
        mounted = host; host.frame = root.bounds; host.autoresizingMask = [.width, .height]; root.addSubview(host)
    }
    static func uninstall(in root: NSView, accepted: ((Bool) -> Void)? = nil) {
        present(in: root, title: L10n.uninstallTitle, message: L10n.uninstallDetail + "\n\n" + L10n.uninstallRemoveHint,
                primary: L10n.uninstallAction, checkbox: L10n.uninstallKeepData, emphasizePrimary: true) { keep in
            Task { @MainActor in
                if let accepted { accepted(keep); return }
                do { try await MaintenanceClient.launch(.uninstall(keepData: keep)) }
                catch { showError(error, in: root) }
            }
        }
    }
    static func dictionary(in root: NSView) {
        present(in: root, title: L10n.dictionaryManage, message: L10n.dictionaryManageHint + "\n\n" + L10n.installResetHint,
                primary: L10n.installReset) { _ in try InputMethodInstallation.shared.resetDictionaryAndRestart() }
    }
    /// A two-way choice. Dismissing the dialog counts as the close choice.
    @discardableResult static func choose(in root: NSView, title: String, message: String, primary: String, close: String,
                                          onPrimary: @escaping () -> Void, onClose: @escaping () -> Void) -> NSView {
        var visible = true
        weak var mounted: NSView?
        let description = FluentSelectableLabel(wrappingLabelWithString: message)
        description.font = IMEFont.font(ofSize: 14); description.textColor = Preferences.shared.theme.textPrimary
        let height = ceil(description.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 380, height: 1000)).height ?? 60)
        let content = IMEFlippedView(frame: NSRect(x: 0, y: 0, width: 380, height: height))
        description.frame = content.bounds; content.addSubview(description)
        let dialog = FluentContentDialog(isPresented: FluentBinding(get: { visible }, set: { visible = $0 }),
            configuration: .init(title: title, primaryButtonText: primary, closeButtonText: close, defaultButton: .primary),
            onClosed: { result in
                mounted?.removeFromSuperview()
                if result == .primary { onPrimary() } else { onClose() }
            }, content: { FluentEmptyView() }, dialogContent: { FluentNativeView(content).frame(width: 380, height: height) })
        let host = dialog._makeView(in: FluentRenderContext(theme: Preferences.shared.theme, locale: L10n.locale))
        mounted = host; host.frame = root.bounds; host.autoresizingMask = [.width, .height]; root.addSubview(host)
        return host
    }
    static func showError(_ error: Error, in root: NSView) {
        var visible = true
        weak var mounted: NSView?
        let dialog = FluentContentDialog(isPresented: FluentBinding(get: { visible }, set: { visible = $0 }),
            configuration: .init(title: L10n.commonOperationFailed, primaryButtonText: L10n.commonClose, defaultButton: .primary),
            onClosed: { _ in
                mounted?.removeFromSuperview()
                if InputMethodInstallation.shared.needsQuitAfterFailure { NSApp.terminate(nil) }
            }, content: { FluentEmptyView() }, dialogContent: { FluentText(error.localizedDescription) })
        let host = dialog._makeView(in: FluentRenderContext(theme: Preferences.shared.theme, locale: L10n.locale))
        mounted = host; host.frame = root.bounds; host.autoresizingMask = [.width, .height]; root.addSubview(host)
    }
}
