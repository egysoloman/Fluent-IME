import Foundation

/// Vendored Fluent artwork, available to both the input method and maintenance app.
public enum UpdateArtwork: String, CaseIterable {
    case warning = "warning_3d"
    case offline = "globe_with_meridians_3d"
    case current = "check_mark_button_3d"
    case available = "counterclockwise_arrows_button_3d"
    case sync = "update-sync"
    case history = "update-history"
    case preview = "update-preview"
    public var url: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: self == .sync || self == .history || self == .preview ? "pdf" : "png")
    }
}
