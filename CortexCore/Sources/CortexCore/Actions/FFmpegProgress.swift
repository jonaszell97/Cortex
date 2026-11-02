import Foundation

/// Follows ffmpeg's standard error: the input's `Duration:` first, then
/// `time=` in every status line.
public struct FFmpegProgress: Sendable {
    public private(set) var duration: Double?
    public private(set) var fraction: Double?

    public init() {}

    /// Returns true when `fraction` changed.
    @discardableResult
    public mutating func consume(_ line: String) -> Bool {
        if duration == nil, let value = Self.time(after: "Duration: ", in: line), value > 0 {
            duration = value
            return false
        }
        guard let duration, let time = Self.time(after: "time=", in: line) else { return false }
        let new = min(max(time / duration, 0), 1)
        guard new != fraction else { return false }
        fraction = new
        return true
    }

    /// Parses `HH:MM:SS.ss` right after `marker`.
    static func time(after marker: String, in line: String) -> Double? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...].prefix { $0.isNumber || $0 == ":" || $0 == "." }
        let parts = rest.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
