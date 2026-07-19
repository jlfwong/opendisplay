// Wire input events: Apple Pencil + multi-touch, sent phone → Mac on the
// control channel. JSON-encoded, one framed message per event.
//
// Finger mapping (Mac interprets):
//   1 finger tap/drag → left mouse click/drag
//   2 finger tap → Cmd+Z undo; 3 finger tap → Cmd+Shift+Z redo
//   2 finger pinch → Control+scroll zoom at pinch centroid
//   Pencil stroke → tablet pen; pencil tap (no movement) → right click
//   Pencil hover → cursor move without drawing

import Foundation

enum WireInput {
    static let pencil = "pencil"
    static let proximity = "proximity"
    static let gesture = "gesture"
    static let barrelButton = "barrelButton"
}

enum PencilPhase: String {
    case down, move, up, hover
}

enum GestureKind: String {
    case pinch, rotate, pan, tap, longPress, swipe
}

enum GestureState: String {
    case began, changed, ended, cancelled
}
