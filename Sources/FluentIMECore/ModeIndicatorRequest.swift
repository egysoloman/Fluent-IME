/// A focus change establishes a baseline; only a subsequent mode change may
/// display a hint. Queued hints expire on typing, another switch, or blur.
public struct ModeIndicatorRequest {
    private var mode: InputMode?
    private var generation: UInt = 0
    private var active = false
    public init() {}
    public mutating func activate(mode: InputMode) {
        generation &+= 1; self.mode = mode; active = true
    }
    public mutating func cancel() { generation &+= 1 }
    public mutating func deactivate() { cancel(); active = false }
    public mutating func changed(to mode: InputMode) -> UInt? {
        guard active, self.mode != mode else { return nil }
        self.mode = mode; cancel(); return generation
    }
    public func accepts(_ request: UInt) -> Bool { active && request == generation }
}
