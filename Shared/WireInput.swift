// Wire input events: Apple Pencil + multi-touch, sent phone → Mac on the
// control channel. JSON-encoded, one framed message per event.
//
// Finger mapping (Mac interprets):
//   touches contact frames → TouchGestureRecognizer → mouse / scroll / pinch / undo / redo
//   Pencil stroke → tablet pen; pencil tap (no movement) → left click
//   Pencil hover → cursor move without drawing
//   Pencil side double-tap → right click (barrelButton)

import Foundation

enum WireInput {
    static let pencil = "pencil"
    static let proximity = "proximity"
    static let barrelButton = "barrelButton"
    static let touches = "touches"
    static let key = "key"
}

enum WireKeyCode {
    /// kVK_Option (left Option)
    static let option: UInt16 = 0x3A
    /// kVK_Shift (left Shift)
    static let shift: UInt16 = 0x38
    /// kVK_Control (left Control)
    static let control: UInt16 = 0x3B
    /// kVK_ANSI_A
    static let a: UInt16 = 0x00
    /// kVK_ANSI_Z
    static let z: UInt16 = 0x06
    /// kVK_ANSI_R
    static let r: UInt16 = 0x0F
}

enum PencilPhase: String {
    case down, move, up, hover
}

enum TouchContactPhase: String, Codable {
    case began, moved, ended, cancelled
}

/// One finger contact in a `touches` frame.
struct WireTouchContact: Codable, Equatable {
    let id: Int
    let phase: TouchContactPhase
    /// Video-normalized [0,1], origin top-left.
    let x: Double
    let y: Double
    /// Normalized contact major radius (optional).
    var major: Double?
}
