import Foundation

/// The player's settings and a stream's headers written as mpv options — apart from the engine.
enum MPVOptions {

    /// Every header but the user agent and referrer, which mpv takes as options of their own, as
    /// `http-header-fields`: `Key: Value` entries joined by commas, in key order. mpv splits the
    /// list on commas, so one inside a value is escaped.
    static func headerFields(_ headers: [String: String]) -> String {
        headers
            .filter { !["user-agent", "referer"].contains($0.key.lowercased()) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.replacingOccurrences(of: ",", with: "\\,"))" }
            .joined(separator: ",")
    }

    static func userAgent(_ headers: [String: String]) -> String? {
        value(of: "user-agent", in: headers)
    }

    static func referrer(_ headers: [String: String]) -> String? {
        value(of: "referer", in: headers)
    }

    private static func value(of name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }

    /// The `seek` command's flags for a precision.
    static func seekFlags(_ precision: SeekPrecision) -> String {
        switch precision {
        case .fast: return "absolute+keyframes"
        case .exact: return "absolute+exact"
        case .within: return "absolute"
        }
    }

    /// `hls-bitrate`: the highest variant, or the one nearest a cap.
    static func hlsBitrate(_ bitsPerSecond: Int?) -> String {
        bitsPerSecond.map(String.init) ?? "max"
    }

    /// `sub-delay` for the delay the subtitle settings hold. The overlay shows a cue at
    /// `time + delay`, so a positive delay shows it sooner; mpv's positive shows it later.
    static func subDelay(fromOverlayDelay delay: Double) -> Double {
        -delay
    }

    /// `sub-scale` for the subtitle size the viewer set, in points on a 24-point base.
    static func subScale(fontSize: Double) -> Double {
        fontSize / 24
    }

    /// `volume` is a percentage.
    static func volume(_ volume: Float) -> Double {
        Double(volume) * 100
    }
}
