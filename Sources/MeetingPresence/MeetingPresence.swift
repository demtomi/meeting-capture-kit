// MeetingPresence — the two decisions behind "a call is happening on that screen",
// with no AppKit, no CoreGraphics window list and no TCC.
//
// Split out for the same reason as ScreenPreset and SilenceGate: both rules fail
// SILENTLY and in opposite directions, and neither is checkable by a compiler.
//
//   CallPresence   — "a new call window appeared". Too eager and it re-prompts every
//                    30 s for a Zoom window left open all day. Too lazy and the
//                    second meeting of the morning never prompts at all. The
//                    difference is one line about when an id leaves the seen set.
//
//   PanelAnchor    — "the host moved this panel, so stop moving it back". A status panel
//                    is re-anchored on every content size change, and it grows when the
//                    no-remote-audio alarm appears. So a panel dragged to a comfortable
//                    spot snaps back to the right edge the moment the call goes quiet,
//                    at the exact moment the host is looking at it.
//
// Both are replayable by `swift run meeting-presence-check` with nothing plugged in.
import Foundation
import ScreenPreset

// MARK: - Call presence

/// One on-screen window that `ScreenPreset.isConferenceWindow` accepted, carrying the
/// window-server id so appearances can be told apart from continuations.
///
/// The id is the identity, NOT the app: two back-to-back Zoom calls are two windows,
/// and a single window that stays open across a lunch break is still one.
public struct CallWindow: Equatable, Sendable {
    public let windowID: UInt32
    public let info: WindowInfo

    public init(windowID: UInt32, info: WindowInfo) {
        self.windowID = windowID
        self.info = info
    }
}

public struct CallPresence: Sendable {
    /// Window ids we have already raised a prompt for. An id is only forgotten when the
    /// window CLOSES, which is what makes "prompt once per call" true across a poll
    /// running every few seconds for an hour.
    private var prompted: Set<UInt32> = []
    /// Everything currently on screen, so a close can be detected as an absence.
    private var present: Set<UInt32> = []

    public init() {}

    public var promptedCount: Int { prompted.count }

    /// Feed the current set of conference windows. Returns the one worth prompting for,
    /// or nil.
    ///
    /// Largest-first when several appear at once: a Zoom call typically opens a main
    /// window and a control strip in the same poll, and the main window is the meeting.
    /// (`isConferenceWindow` already drops anything under 200x150, which removes most
    /// of them, but two real windows can still arrive together.)
    public mutating func observe(_ windows: [CallWindow]) -> CallWindow? {
        let now = Set(windows.map(\.windowID))

        // Forget closed windows. Without this the set grows without bound across a day
        // and — far worse — a REUSED window id would be silently swallowed as already
        // prompted. The window server does reuse ids.
        prompted.formIntersection(now)
        present = now

        let fresh = windows
            .filter { !prompted.contains($0.windowID) }
            .sorted { $0.info.frame.area > $1.info.frame.area }

        guard let pick = fresh.first else { return nil }
        // Mark EVERY fresh window prompted, not just the one returned. Otherwise the
        // control strip that lost the size comparison prompts on the very next poll,
        // which is the same meeting asking twice.
        for w in fresh { prompted.insert(w.windowID) }
        return pick
    }

    /// The call to place panels against: the largest conference window on screen right
    /// now, prompted or not. Placement is about where the meeting IS, which has nothing
    /// to do with whether it has already been offered a prompt.
    public func currentCall(_ windows: [CallWindow]) -> CallWindow? {
        windows.max(by: { $0.info.frame.area < $1.info.frame.area })
    }

    /// Test seam: pretend these ids are already prompted.
    public mutating func seed(prompted ids: [UInt32]) {
        prompted.formUnion(ids)
        present.formUnion(ids)
    }
}

// MARK: - Panel anchoring

/// A panel origin in plain Doubles.
///
/// NOT `CGPoint`, for the same reason `ScreenPreset` defines its own `Rect`: this
/// library must stay free of CoreGraphics. It is also not merely stylistic — a
/// `CGPoint` in this API crashed the RELEASE build outright (`swift-frontend` signal 6,
/// "DESERIALIZATION FAILURE … Cross-reference to module 'CoreFoundation' … CGPoint …
/// x"), while the debug build compiled and every check passed. Cross-module
/// optimization could not resolve the CoreGraphics cross-reference out of a module that
/// only imports Foundation.
public struct PanelPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Tracks whether the host has dragged a floating panel, so automatic placement can
/// stand down for the rest of that panel's life.
///
/// The comparison is against the LAST ORIGIN WE SET, never against a fixed anchor.
/// Automatic re-anchoring moves the panel legitimately and often (it re-anchors on every
/// size change), so anything that compares to a start position reads our own moves as the
/// host's and freezes placement after the first alarm.
public struct PanelAnchor: Sendable {
    /// Slack for float rounding on setFrameOrigin and for the AppKit y-flip. A real
    /// drag is tens of points; this only has to survive arithmetic.
    public static let tolerance: Double = 2.0

    private var lastProgrammatic: PanelPoint?
    private(set) public var userMoved = false

    public init() {}

    /// Call immediately after `setFrameOrigin`, with the origin actually set.
    public mutating func noteProgrammaticMove(to origin: PanelPoint) {
        lastProgrammatic = origin
    }

    /// Call from the window's didMove notification. Returns true when this move was the
    /// host's, which latches `userMoved` on for good.
    @discardableResult
    public mutating func noteObservedOrigin(_ origin: PanelPoint) -> Bool {
        guard let last = lastProgrammatic else {
            // A move before we ever placed it. Treat as ours: the window server emits a
            // didMove during creation, and latching on that would freeze every panel
            // before it was ever shown.
            lastProgrammatic = origin
            return false
        }
        let moved = abs(origin.x - last.x) > Self.tolerance
                 || abs(origin.y - last.y) > Self.tolerance
        if moved { userMoved = true }
        // Track it either way, so the NEXT comparison is against where the panel now is.
        lastProgrammatic = origin
        return moved
    }

    /// The whole point: may automatic placement move this panel?
    public var mayReposition: Bool { !userMoved }
}
