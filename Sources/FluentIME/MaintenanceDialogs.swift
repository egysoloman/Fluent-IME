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
    static func uninstall(in root: NSView) {
        present(in: root, title: L10n.uninstallTitle, message: L10n.uninstallDetail + "\n\n" + L10n.uninstallRemoveHint,
                primary: L10n.uninstallAction, checkbox: L10n.uninstallKeepData, emphasizePrimary: true) { keep in try InputMethodInstallation.shared.uninstall(keepData: keep) }
    }
    static func dictionary(in root: NSView) {
        present(in: root, title: L10n.dictionaryManage, message: L10n.dictionaryManageHint + "\n\n" + L10n.installResetHint,
                primary: L10n.installReset) { _ in try InputMethodInstallation.shared.resetDictionaryAndRestart() }
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
