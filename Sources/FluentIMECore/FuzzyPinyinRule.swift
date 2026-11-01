/// Bit values are persisted and correspond to the bundled Rime spelling prisms.
public enum FuzzyPinyinRule: Int, CaseIterable {
    case zZh = 1, cCh = 2, sSh = 4, nL = 8, fH = 16, anAng = 32, enEng = 64, inIng = 128

    public var title: String {
        switch self {
        case .zZh: return "z / zh"
        case .cCh: return "c / ch"
        case .sSh: return "s / sh"
        case .nL: return "n / l"
        case .fH: return "f / h"
        case .anAng: return "an / ang"
        case .enEng: return "en / eng"
        case .inIng: return "in / ing"
        }
    }
    public static let validMask = allCases.reduce(0) { $0 | $1.rawValue }
}
