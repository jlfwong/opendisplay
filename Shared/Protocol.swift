// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 2

    /// Default control port (video + input). Trace uses `tracePort(controlPort:)`.
    static let defaultControlPort: UInt16 = 9000

    /// Dedicated trace stream — same framing as control, but isolated from pencil.
    static func tracePort(controlPort: UInt16) -> UInt16 { controlPort + 1 }

    /// Tiny heartbeat stream on its own usbmux connection (controlPort + 2).
    /// Isolated from video+input on :9000 so we can see per-connection vs pipe stalls.
    static func heartbeatPort(controlPort: UInt16) -> UInt16 { controlPort + 2 }

    /// Follow-up after input send completes — carries Mac-unified `tSend` (contentProcessed).
    static let inpSent = "inpSent"

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
}

/// Heartbeat channel (port controlPort + 2) — length-prefixed JSON, same as control.
enum WireHeartbeat {
    static let ping = "hb"
    static let pong = "hbPong"
}
