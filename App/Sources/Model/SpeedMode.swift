/// How fast downloads may go, as one switch for all of them together (the engine's global limit).
enum SpeedMode: String, CaseIterable, Identifiable, Sendable {
    case low, normal, high

    var id: Self { self }

    /// The starting limits in KB/s. Low and Normal can be changed in Settings; High is always unlimited.
    static let defaultLowKBps = 1024
    static let defaultNormalKBps = 4096
}
