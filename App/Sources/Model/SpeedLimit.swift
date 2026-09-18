/// Converts the KB/s numbers people type into bytes per second, without letting a huge value overflow.
enum SpeedLimit {
    /// 10 GB/s: far beyond any real link, and low enough that KB/s x 1000 cannot overflow an `Int64`.
    static let maxKBps = 10_000_000

    static func clamp(_ kbps: Int) -> Int { min(max(kbps, 0), maxKBps) }

    /// Bytes per second for a KB/s value; `nil` (unlimited) for zero or less.
    static func bytesPerSecond(kbps: Int) -> Int64? {
        let clamped = clamp(kbps)
        return clamped > 0 ? Int64(clamped) * 1000 : nil
    }
}
