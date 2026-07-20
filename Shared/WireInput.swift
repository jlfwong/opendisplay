// Wire input events: Apple Pencil + multi-touch, sent phone → Mac on the
// control channel. JSON-encoded, one framed message per event.
//
// Finger mapping (Mac interprets):
//   touches contact frames → TouchGestureRecognizer → mouse / scroll / pinch / undo / redo
//   Pencil stroke → tablet pen; pencil tap (no movement) → left click
//   Pencil hover → cursor move without drawing

import Foundation

enum WireInput {
    static let pencil = "pencil"
    static let proximity = "proximity"
    static let barrelButton = "barrelButton"
    static let touches = "touches"
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
