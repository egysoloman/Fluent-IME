import AppKit
import FluentKit
import FluentIMECore

class UpdateLayoutView: IMEFlippedView {
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
}

private class UpdateCard: UpdateLayoutView {
    var theme = IMEThemeObservation.current { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        (theme.isDark ? NSColor.white.withAlphaComponent(0.035) : NSColor.white.withAlphaComponent(0.65)).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6); path.fill()
        theme.surfaceStrokeFlyout.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}

private final class UpdateTextView: NSTextView {
    private var flyout: FluentMenuFlyout?
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) } else { super.mouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        flyout = FluentMenuFlyout(items: [
            FluentMenuItem(id: "copy", L10n.menuCopy, keyEquivalent: "c") { [weak self] in self?.copy(nil) },
            FluentMenuItem(id: "selectAll", L10n.menuSelectAll, keyEquivalent: "a") { [weak self] in self?.selectAll(nil) }
        ], theme: IMEThemeObservation.current, matchesAnchorWidth: false)
        flyout?.present(relativeTo: self, at: convert(event.locationInWindow, from: nil))
    }
}

/// Release notes are selectable text, never an embedded remote web page.
private final class UpdateNotes: NSScrollView {
    private let text = UpdateTextView()
    var notes = "" { didSet { refresh() } }
    var theme = IMEThemeObservation.current { didSet { refresh() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; hasVerticalScroller = false
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        documentView = text
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() {
        let result = NSMutableAttributedString(string: "")
        let normalized = notes.prefix(40_000).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let newline = index < lines.count - 1 ? "\n" : ""
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 4
            if trimmed.isEmpty {
                paragraph.paragraphSpacing = 0
                result.append(NSAttributedString(string: newline, attributes: [.font: IMEFont.font(ofSize: 6, weight: .regular), .paragraphStyle: paragraph]))
                continue
            }
            var size: CGFloat = 13, weight: NSFont.Weight = .regular, content = trimmed, prefix = ""
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...3).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
                content = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                size = [16, 14.5, 13.5][hashes - 1]; weight = .semibold
                paragraph.paragraphSpacing = 6; paragraph.paragraphSpacingBefore = index == 0 ? 0 : 6
            } else if let bullet = trimmed.first, "-*+".contains(bullet), trimmed.dropFirst().hasPrefix(" ") {
                content = String(trimmed.dropFirst(2)); prefix = "•  "
                paragraph.firstLineHeadIndent = 0; paragraph.headIndent = 14
            } else if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex, trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                prefix = String(trimmed[...dot]) + " "; content = String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                paragraph.headIndent = 18
            }
            let line = NSMutableAttributedString(string: prefix, attributes: [.font: IMEFont.font(ofSize: size, weight: weight), .foregroundColor: theme.textSecondary])
            line.append(inline(content, size: size, weight: weight))
            line.append(NSAttributedString(string: newline))
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        text.textStorage?.setAttributedString(result)
        text.setAccessibilityLabel(L10n.updateNotesTitle)
        needsLayout = true
    }
    /// Inline spans: **bold**, `code` and [label](url).
    private func inline(_ source: String, size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: IMEFont.font(ofSize: size, weight: weight), .foregroundColor: theme.textPrimary]
        let chars = Array(source)
        var i = 0, plain = ""
        func flush() { if !plain.isEmpty { out.append(NSAttributedString(string: plain, attributes: base)); plain = "" } }
        func find(_ token: [Character], from: Int) -> Int? {
            guard from + token.count <= chars.count else { return nil }
            for k in from...(chars.count - token.count) where Array(chars[k..<k + token.count]) == token { return k }
            return nil
        }
        while i < chars.count {
            if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*", let end = find(["*", "*"], from: i + 2), end > i + 2 {
                flush()
                var attributes = base; attributes[.font] = IMEFont.font(ofSize: size, weight: .semibold)
                out.append(NSAttributedString(string: String(chars[i + 2..<end]), attributes: attributes)); i = end + 2
            } else if chars[i] == "`", let end = find(["`"], from: i + 1), end > i + 1 {
                flush()
                var attributes = base
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: max(11.5, size - 1), weight: .regular)
                attributes[.backgroundColor] = theme.subtleFillSecondary
                out.append(NSAttributedString(string: String(chars[i + 1..<end]), attributes: attributes)); i = end + 1
            } else if chars[i] == "[", let mid = find(["]", "("], from: i + 1), let end = find([")"], from: mid + 2) {
                flush()
                var attributes = base
                attributes[.foregroundColor] = theme.accent
                if let url = URL(string: String(chars[mid + 2..<end])) { attributes[.link] = url }
                out.append(NSAttributedString(string: String(chars[i + 1..<mid]), attributes: attributes)); i = end + 1
            } else { plain.append(chars[i]); i += 1 }
        }
        flush()
        return out
    }
    override func layout() {
        super.layout()
        text.frame.size.height = max(contentSize.height, fittingHeight(for: contentSize.width))
    }
    func fittingHeight(for width: CGFloat) -> CGFloat {
        let width = max(1, width)
        text.frame.size.width = width
        text.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let container = text.textContainer, let manager = text.layoutManager {
            manager.ensureLayout(for: container)
            return ceil(manager.usedRect(for: container).maxY + text.textContainerInset.height * 2)
        }
        return 0
    }
}

@MainActor private func updateLabel(_ field: NSTextField, size: CGFloat = 14, secondary: Bool = false, bold: Bool = false) {
    field.font = IMEFont.font(ofSize: size, weight: bold ? .semibold : .regular)
    field.textColor = secondary ? IMEThemeObservation.current.textSecondary : IMEThemeObservation.current.textPrimary
}
@MainActor private func updateTextHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
    ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude)).height ?? 22)
}
private func releaseNotes(_ release: GitHubRelease) -> String {
    let value = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? L10n.updateNotesEmpty : value
}
private func releaseCaption(_ release: GitHubRelease) -> String {
    var pieces = [release.prerelease ? L10n.updateChannelPreview : L10n.updateChannelStable]
    if let raw = release.published_at, let date = ISO8601DateFormatter().date(from: raw) {
        pieces.append(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
    }
    return ([release.tag_name] + pieces).joined(separator: " · ")
}

@MainActor private final class UpdateOptionCell: UpdateCard {
    let toggle = FluentToggle(title: "", isOn: false)
    private let titleLabel: NSTextField
    private let subtitle: NSTextField
    private let icon = NSImageView()
    private let glyph: SettingsGlyph
    private let navigate = NSButton()
    private let arrow = NSTextField(labelWithString: "›")
    var onClick: (() -> Void)?
    private let isNavigation: Bool
    init(title: String, hint: String, glyph: SettingsGlyph, navigation: Bool = false) {
        titleLabel = NSTextField(wrappingLabelWithString: title); subtitle = NSTextField(wrappingLabelWithString: hint)
        self.glyph = glyph; isNavigation = navigation
        super.init(frame: .zero)
        for view in [icon, titleLabel, subtitle, toggle, arrow, navigate] { addSubview(view) }
        toggle.setAccessibilityLabel(title); toggle.isHidden = navigation; arrow.isHidden = !navigation
        navigate.isHidden = !navigation; navigate.title = ""; navigate.isBordered = false; navigate.target = self; navigate.action = #selector(clicked)
        navigate.setAccessibilityLabel(title); refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { onClick?() }
    func refresh() {
        theme = IMEThemeObservation.current; toggle.theme = theme
        updateLabel(titleLabel); updateLabel(subtitle, size: 12, secondary: true); updateLabel(arrow, size: 24)
        icon.image = glyph.image(color: theme.textPrimary, pointSize: 30)
        icon.imageScaling = .scaleProportionallyUpOrDown
    }
    func fittingHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - 144)
        return max(76, updateTextHeight(titleLabel, width: textWidth) + 5 + updateTextHeight(subtitle, width: textWidth) + 32)
    }
    override func layout() {
        super.layout()
        let textWidth = max(1, bounds.width - 144)
        let titleHeight = updateTextHeight(titleLabel, width: textWidth), subtitleHeight = updateTextHeight(subtitle, width: textWidth)
        let textY = (bounds.height - titleHeight - 5 - subtitleHeight) / 2
        icon.frame = NSRect(x: 16, y: (bounds.height - 30) / 2, width: 30, height: 30)
        titleLabel.frame = NSRect(x: 62, y: textY, width: textWidth, height: titleHeight)
        subtitle.frame = NSRect(x: 62, y: titleLabel.frame.maxY + 5, width: textWidth, height: subtitleHeight)
        toggle.frame = NSRect(x: bounds.width - 58, y: (bounds.height - 24) / 2, width: 40, height: 24)
        arrow.frame = NSRect(x: bounds.width - 36, y: (bounds.height - 30) / 2, width: 20, height: 30)
        navigate.frame = bounds
    }
}

@MainActor private enum UpdateStatusImages {
    static let images: [UpdateArtwork: NSImage] = Dictionary(uniqueKeysWithValues: UpdateArtwork.allCases.compactMap { asset in
        asset.url.flatMap { NSImage(contentsOf: $0) }.map { (asset, $0) }
    })
}

@MainActor final class UpdatePageView: UpdateLayoutView {
    private let coordinator: UpdateCoordinator
    private let icon = NSImageView()
    private let version = NSTextField(labelWithString: "")
    private let status = FluentSelectableLabel(wrappingLabelWithString: "")
    private let lastCheck = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = FluentProgressBar(value: 0)
    private let primary = FluentButton(title: "", role: .primary)
    private let cancel = FluentButton(title: L10n.commonCancel)
    private let notesCard = UpdateCard()
    private let notesTitle = NSTextField(labelWithString: L10n.updateNotesTitle)
    private let releaseTitle = NSTextField(labelWithString: "")
    private let notes = UpdateNotes()
    private let more = NSTextField(labelWithString: L10n.updateMoreOptions)
    private let incremental = UpdateOptionCell(title: L10n.updatePreferIncremental, hint: L10n.updatePreferIncrementalHint, glyph: .advanced)
    private let preview = UpdateOptionCell(title: L10n.updateReceivePrerelease, hint: L10n.updateReceivePrereleaseHint, glyph: .updatePreview)
    private let automatic = UpdateOptionCell(title: L10n.updateAutomaticChecks, hint: L10n.updateAutomaticChecksHint, glyph: .updates)
    private let history = UpdateOptionCell(title: L10n.updateHistoryTitle, hint: L10n.updateHistoryCellHint, glyph: .updateHistory, navigation: true)
    private var notesStamp = ""
    private var observer: NSObjectProtocol?
    private var themeObservation: IMEThemeObservation?
    var onOpenHistory: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    private(set) var preferredHeight: CGFloat = 600
    convenience init() { self.init(coordinator: .shared) }
    init(coordinator: UpdateCoordinator) {
        self.coordinator = coordinator; super.init(frame: .zero)
        progress.translatesAutoresizingMaskIntoConstraints = true
        for view in [icon, version, status, detail, progress, lastCheck, primary, cancel, notesCard, more, incremental, preview, automatic, history] { addSubview(view) }
        for view in [releaseTitle, notesTitle, notes] { notesCard.addSubview(view) }
        primary.onClick = { [weak coordinator] in guard let coordinator else { return }; if coordinator.canInstall { coordinator.install() } else { coordinator.check() } }
        cancel.onClick = { [weak coordinator] in coordinator?.cancel() }
        incremental.toggle.onValueChanged = { [weak coordinator] value in coordinator?.preferIncremental = value }
        preview.toggle.onValueChanged = { [weak coordinator] value in coordinator?.selectChannel(value ? .preview : .stable) }
        automatic.toggle.onValueChanged = { [weak coordinator] value in coordinator?.automaticChecks = value }
        history.onClick = { [weak self] in self?.onOpenHistory?() }
        observer = NotificationCenter.default.addObserver(forName: UpdateCoordinator.changed, object: coordinator, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        themeObservation = IMEThemeObservation { [weak self] _ in self?.refresh() }
        refresh(); coordinator.checkAutomaticallyIfDue()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        let theme = IMEThemeObservation.current
        let artwork: UpdateArtwork
        switch coordinator.state {
        case .current: artwork = .current
        case .failed: artwork = coordinator.connectionFailed ? .offline : .warning
        default: artwork = .available
        }
        icon.image = UpdateStatusImages.images[artwork]; icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(artwork == .offline ? L10n.updateConnectionFailed : artwork == .warning ? L10n.updateCheckFailed : artwork == .current ? L10n.updateCurrent(coordinator.currentVersion) : L10n.updatePageTitle)
        version.stringValue = L10n.updateInstalledVersion(coordinator.currentVersion)
        updateLabel(version, size: 12, secondary: true); updateLabel(status, size: 18, bold: true); status.theme = theme
        updateLabel(lastCheck, size: 12, secondary: true); updateLabel(detail, size: 12, secondary: true)
        // Equal-width digits keep the right-aligned progress from shifting as it counts.
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); detail.alignment = .right
        lastCheck.stringValue = coordinator.lastChecked.map { L10n.updateLastChecked(DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)) } ?? L10n.updateNotChecked
        for button in [primary, cancel] { button.theme = theme }
        progress.theme = theme; progress.isHidden = !coordinator.busy
        if case .downloading(_, let total) = coordinator.state { progress.isIndeterminate = total <= 0 }
        else { progress.isIndeterminate = true }
        detail.stringValue = ""
        var errorMessage: String?
        switch coordinator.state {
        case .idle: status.stringValue = L10n.updateIdle
        case .checking: status.stringValue = L10n.updateChecking
        case .available: status.stringValue = L10n.updateReady
        case .current: status.stringValue = L10n.updateCurrent(coordinator.currentVersion)
        case .downloading(let received, let total):
            status.stringValue = L10n.updateDownloadStatus
            progress.value = total > 0 ? min(100, Double(received) / Double(total) * 100) : 0
            // One fixed decimal, so 92 MB and 92.5 MB take the same width.
            func megabytes(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
            detail.stringValue = total > 0 ? "\(Int(progress.value))% · \(megabytes(received)) / \(megabytes(total))" : megabytes(received)
        case .verifying: status.stringValue = L10n.updateVerifying
        case .opening: status.stringValue = L10n.updateOpening
        case .opened: status.stringValue = L10n.updateOpened
        case .cancelled: status.stringValue = L10n.updateCancelled
        case .failed(let message): status.stringValue = L10n.updateCheckFailed; errorMessage = message
        }
        primary.title = coordinator.canInstall ? L10n.updateInstall : L10n.updateTitle
        primary.setAccessibilityLabel(primary.title); primary.isEnabled = !coordinator.busy
        cancel.isHidden = !coordinator.busy
        if case .opening = coordinator.state { cancel.isEnabled = false } else { cancel.isEnabled = true }
        notesCard.theme = theme
        updateLabel(notesTitle, size: 12, secondary: true); updateLabel(releaseTitle, size: 14, bold: true); updateLabel(more, size: 18, bold: true)
        let release = coordinator.latestRelease.flatMap { latest in coordinator.history.first { $0.tag_name == latest.tag_name } ?? latest }
        releaseTitle.stringValue = errorMessage == nil ? release.map { L10n.updateReleaseLabel($0.version) } ?? L10n.updateNotesTitle : L10n.updateCheckFailed
        notesTitle.stringValue = release.map(releaseCaption) ?? ""
        let body = errorMessage ?? release.map(releaseNotes) ?? L10n.updateNotesPending
        if notesStamp != body { notesStamp = body; notes.notes = body }
        if notes.theme != theme { notes.theme = theme }
        incremental.isHidden = FluentProduct.current != .pinyin
        for cell in [incremental, preview, automatic, history] { cell.refresh() }
        // Programmatic synchronization must not trigger a new check or write preferences.
        let previewChanged = preview.toggle.onValueChanged, autoChanged = automatic.toggle.onValueChanged, incChanged = incremental.toggle.onValueChanged
        preview.toggle.onValueChanged = nil; automatic.toggle.onValueChanged = nil; incremental.toggle.onValueChanged = nil
        preview.toggle.isOn = coordinator.channel == .preview; automatic.toggle.isOn = coordinator.automaticChecks
        incremental.toggle.isOn = coordinator.preferIncremental
        preview.toggle.onValueChanged = previewChanged; automatic.toggle.onValueChanged = autoChanged; incremental.toggle.onValueChanged = incChanged
        preview.toggle.isEnabled = coordinator.canChangeChannel
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = max(1, bounds.width), actionWidth = max(152, primary.intrinsicContentSize.width + 12)
        let textX: CGFloat = 104
        let textWidth = max(1, width - textX - actionWidth - 20)
        // Download progress sits at the right end of the status line, above the bar's end.
        let detailWidth: CGFloat = detail.stringValue.isEmpty ? 0 : 200
        let statusHeight = updateTextHeight(status, width: max(1, textWidth - detailWidth))
        // Like Windows Update, a running check or download shows its bar under the status, up to the action button.
        let progressSpace: CGFloat = progress.isHidden ? 0 : 14
        let headerHeight = max(92, statusHeight + 52 + progressSpace)
        let textY = (headerHeight - statusHeight - 46 - progressSpace) / 2
        icon.frame = NSRect(x: 0, y: (headerHeight - 84) / 2, width: 84, height: 84)
        status.frame = NSRect(x: textX, y: textY, width: max(1, textWidth - detailWidth), height: statusHeight)
        progress.frame = NSRect(x: textX, y: status.frame.maxY + 8, width: max(1, width - actionWidth - 16 - textX), height: 4)
        detail.frame = NSRect(x: progress.frame.maxX - detailWidth, y: status.frame.maxY - 20, width: detailWidth, height: 18)
        lastCheck.frame = NSRect(x: textX, y: status.frame.maxY + 8 + progressSpace, width: width - textX, height: 18)
        version.frame = NSRect(x: textX, y: lastCheck.frame.maxY + 2, width: width - textX, height: 18)
        primary.frame = NSRect(x: width - actionWidth, y: (headerHeight - 32) / 2, width: actionWidth, height: 32)
        cancel.frame = primary.frame; primary.isHidden = coordinator.busy
        releaseTitle.frame = NSRect(x: 16, y: 14, width: width - 32, height: 24)
        var y: CGFloat = releaseTitle.frame.maxY + 8
        notesTitle.frame = NSRect(x: 16, y: y, width: width - 32, height: 20)
        if !notesTitle.stringValue.isEmpty { y += 28 }
        notes.frame = NSRect(x: 16, y: y, width: width - 32, height: notes.fittingHeight(for: width - 32))
        notesCard.frame = NSRect(x: 0, y: headerHeight + 24, width: width, height: notes.frame.maxY + 16)
        more.frame = NSRect(x: 0, y: notesCard.frame.maxY + 24, width: width, height: 28)
        y = more.frame.maxY + 16
        let cells = FluentProduct.current == .pinyin ? [incremental, preview, automatic, history] : [preview, automatic, history]
        for cell in cells {
            cell.frame = NSRect(x: 0, y: y, width: width, height: cell.fittingHeight(for: width))
            y = cell.frame.maxY + 8
        }
        let height = y + 16
        if height != preferredHeight { preferredHeight = height; onHeightChange?(height) }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@MainActor final class UpdateHistoryPageView: UpdateLayoutView {
    private let coordinator: UpdateCoordinator
    private let hint = NSTextField(wrappingLabelWithString: L10n.updateHistoryHint)
    private let allReleases = FluentButton(title: L10n.updateAllReleases)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let retry = FluentButton(title: L10n.updateHistoryRetry)
    private let progress = FluentProgressBar(value: 0)
    private var rows: [(UpdateCard, NSTextField, NSTextField, FluentButton, UpdateNotes, FluentButton, String)] = []
    private var expanded = Set<String>(), stamp = ""
    private var observer: NSObjectProtocol?, themeObservation: IMEThemeObservation?
    var onHeightChange: ((CGFloat) -> Void)?
    private(set) var preferredHeight: CGFloat = 180
    convenience init() { self.init(coordinator: .shared) }
    init(coordinator: UpdateCoordinator) {
        self.coordinator = coordinator; super.init(frame: .zero)
        progress.translatesAutoresizingMaskIntoConstraints = true
        for view in [hint, allReleases, status, retry, progress] { addSubview(view) }
        allReleases.onClick = { NSWorkspace.shared.open(GitHubUpdateService.releasesURL) }
        retry.onClick = { [weak coordinator] in coordinator?.loadHistory() }
        observer = NotificationCenter.default.addObserver(forName: UpdateCoordinator.changed, object: coordinator, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        themeObservation = IMEThemeObservation { [weak self] _ in self?.refresh() }
        refresh(); coordinator.loadHistoryIfStale()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        let theme = IMEThemeObservation.current
        updateLabel(hint, size: 13, secondary: true); updateLabel(status, size: 14)
        allReleases.theme = theme; retry.theme = theme; progress.theme = theme
        progress.isIndeterminate = true; progress.isHidden = !coordinator.historyLoading
        let records = coordinator.history
        let newStamp = coordinator.channel.rawValue + records.map { $0.tag_name + ($0.body ?? "") }.joined(separator: "|")
        if stamp != newStamp {
            stamp = newStamp; rows.forEach { $0.0.removeFromSuperview() }; rows = []
            for release in records {
                let card = UpdateCard(), title = NSTextField(labelWithString: L10n.updateReleaseLabel(release.version))
                let subtitle = NSTextField(labelWithString: releaseCaption(release)), toggle = FluentButton(title: "")
                let body = UpdateNotes(), link = FluentButton(title: L10n.updateReleasePage)
                body.notes = releaseNotes(release)
                toggle.onClick = { [weak self] in
                    guard let self else { return }
                    if expanded.contains(release.tag_name) { expanded.remove(release.tag_name) } else { expanded.insert(release.tag_name) }
                    refresh()
                }
                link.onClick = { NSWorkspace.shared.open(release.pageURL) }
                for view in [title, subtitle, toggle, body, link] { card.addSubview(view) }
                addSubview(card); rows.append((card, title, subtitle, toggle, body, link, release.tag_name))
            }
        }
        for (card, title, subtitle, toggle, body, link, tag) in rows {
            card.theme = theme; updateLabel(title, size: 14, bold: true); updateLabel(subtitle, size: 12, secondary: true)
            toggle.title = expanded.contains(tag) ? L10n.updateHideDetails : L10n.updateDetails
            toggle.setAccessibilityLabel(toggle.title + ": " + tag); toggle.theme = theme; link.theme = theme
            if body.theme != theme { body.theme = theme }
            body.isHidden = !expanded.contains(tag); link.isHidden = body.isHidden
        }
        status.stringValue = coordinator.historyLoading ? L10n.updateHistoryLoading : coordinator.historyError ?? (records.isEmpty ? L10n.updateHistoryEmpty : "")
        retry.isHidden = coordinator.historyError == nil || coordinator.historyLoading
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        hint.frame = NSRect(x: 0, y: 0, width: width - 164, height: 44)
        let allWidth = max(148, allReleases.intrinsicContentSize.width + 12)
        allReleases.frame = NSRect(x: width - allWidth, y: 0, width: allWidth, height: 32)
        progress.frame = NSRect(x: 0, y: 50, width: width, height: 4)
        var y: CGFloat = 66
        status.frame = NSRect(x: 0, y: y, width: width - 132, height: 70)
        let retryWidth = max(118, retry.intrinsicContentSize.width + 12)
        retry.frame = NSRect(x: width - retryWidth, y: y, width: retryWidth, height: 32)
        if !status.stringValue.isEmpty { y += 86 }
        for (card, title, subtitle, toggle, body, link, tag) in rows {
            let open = expanded.contains(tag)
            let bodyHeight = open ? body.fittingHeight(for: width - 32) : 0
            card.frame = NSRect(x: 0, y: y, width: width, height: open ? 80 + bodyHeight + 60 : 70)
            title.frame = NSRect(x: 16, y: 12, width: width - 182, height: 22)
            subtitle.frame = NSRect(x: 16, y: 38, width: width - 182, height: 20)
            toggle.frame = NSRect(x: width - 152, y: 18, width: 136, height: 32)
            body.frame = NSRect(x: 16, y: 80, width: width - 32, height: bodyHeight)
            link.frame = NSRect(x: 16, y: body.frame.maxY + 12, width: max(180, link.intrinsicContentSize.width), height: 32)
            y += card.frame.height + 12
        }
        let height = y + 24
        if height != preferredHeight { preferredHeight = height; onHeightChange?(height) }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
