// Latency measurement helpers shared by Mac and iOS.
// See the perf overlay on iOS for live numbers; enable detailed logging with
// Settings → "Latency detail log" or `defaults write … latencyLog -bool true`.

import Foundation

enum LatencyTelemetry {
    static let logPrefix = "[latency]"

    /// Per-sample lines (pen match, encode, inject) when enabled.
    static let detailedLogKey = "latencyLog"

    static var detailedLogEnabled: Bool {
        UserDefaults.standard.bool(forKey: detailedLogKey)
    }
}
