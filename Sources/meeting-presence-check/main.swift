// Runnable verification for MeetingPresence — `swift run meeting-presence-check`.
//
// Two rules, both of which fail silently:
//
//   1. A conference window prompts ONCE. The poll runs every 3 s, so a Zoom window
//      open across an hour is 1,200 observations of the same call. Getting this wrong
//      does not crash anything; it just makes the app unusable in a way that only
//      shows up in a real meeting.
//   2. A panel the host has DRAGGED is never moved again by automatic placement. The
//      pill re-anchors on every content size change, and it changes size exactly when
//      the no-remote-audio alarm appears — so the failure lands at the moment the
//      host is looking at it.
//
// Neither needs a window server, a display, or a TCC grant. An executable rather than
// a testTarget for the same reason as every other check here: Command Line Tools only.
import Foundation
import ScreenPreset
import MeetingPresence

// Unbuffered for the same reason live-audio-check is: through a pipe, a trap would
// take every line printed before it down with the process.
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

@MainActor
func check(_ label: String, _ cond: Bool, breaksIf: String) {
    checks += 1
    if cond {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)")
        print("        should break only if: \(breaksIf)")
    }
}

@MainActor
func section(_ s: String) { print("\n\(s)") }

// A real-shaped Zoom meeting window on the external panel.
func window(_ id: UInt32,
            app: String = "zoom.us",
            bundle: String? = "us.zoom.xos",
            title: String? = "Zoom Meeting",
            w: Double = 1600, h: Double = 900,
            x: Double = 1512, y: Double = 0) -> CallWindow {
    CallWindow(windowID: id,
               info: WindowInfo(bundleID: bundle, appName: app, title: title,
                                frame: Rect(x: x, y: y, width: w, height: h),
                                isOnScreen: true))
}

// ======================================================= call presence — prompt once
section("prompt-once-per-window across a long poll")

var p = CallPresence()
check("no windows means no prompt", p.observe([]) == nil,
      breaksIf: "an empty poll raises a prompt")

let first = p.observe([window(101)])
check("a conference window appearing prompts once", first?.windowID == 101,
      breaksIf: "the appearance is not detected at all")

// The headline: an hour of polling at 3 s. 1,200 observations, one prompt.
var repeats = 0
for _ in 0..<1_200 where p.observe([window(101)]) != nil { repeats += 1 }
print("        1,200 further polls of the same window raised \(repeats) prompts")
check("a window left open for an hour never prompts again", repeats == 0,
      breaksIf: "the prompted set is cleared while the window is still on screen")

// A second, different call while the first is still up.
let second = p.observe([window(101), window(202, app: "Google Chrome",
                                            bundle: "com.google.Chrome",
                                            title: "Weekly sync - Google Meet")])
check("a NEW window alongside the old one prompts", second?.windowID == 202,
      breaksIf: "presence keys on the app rather than the window")

// Two windows arriving in the same poll: the big one wins, and the small one must not
// come back on the next tick claiming to be a second meeting.
var p2 = CallPresence()
let together = p2.observe([window(301, title: "Zoom Meeting", w: 420, h: 260),
                           window(302, w: 1600, h: 900)])
check("when two windows appear together the LARGEST is the meeting",
      together?.windowID == 302,
      breaksIf: "the pick is by iteration order rather than by area")
let echo = p2.observe([window(301, title: "Zoom Meeting", w: 420, h: 260), window(302, w: 1600, h: 900)])
check("the window that lost the size comparison does not prompt on the next poll",
      echo == nil,
      breaksIf: "only the returned window is marked prompted — the control strip asks again")

// Close and reopen. A closed window's id must be forgotten, because the window server
// REUSES ids: a remembered id would swallow the next real meeting silently.
var p3 = CallPresence()
_ = p3.observe([window(400)])
_ = p3.observe([])                                  // the call ends
let reopened = p3.observe([window(400)])
check("after the window closes, the same id prompts again",
      reopened?.windowID == 400,
      breaksIf: "closed ids are never forgotten — a reused id is swallowed as already prompted")

var p4 = CallPresence()
_ = p4.observe([window(500), window(501)])
_ = p4.observe([window(500)])
print("        prompted set holds \(p4.promptedCount) id(s) after one of two closed")
check("the prompted set shrinks when a window closes", p4.promptedCount == 1,
      breaksIf: "the set grows without bound across a working day")

// ==================================================== call presence — where it is
section("placement is independent of prompting")

var p5 = CallPresence()
let live = [window(600, w: 800, h: 600), window(601, w: 1920, h: 1080)]
check("currentCall picks the largest window on screen",
      p5.currentCall(live)?.windowID == 601,
      breaksIf: "placement picks by order instead of area")
_ = p5.observe(live)
check("currentCall still answers after the call has been prompted",
      p5.currentCall(live)?.windowID == 601,
      breaksIf: "placement is gated on the prompt — the pill stops following an ongoing call")
check("currentCall is nil with nothing on screen", p5.currentCall([]) == nil,
      breaksIf: "an empty list resolves to a window anyway")

// The classifier itself is ScreenPreset's and has its own limbs, but the wiring must
// actually consult it — a presence layer that accepted every window would place the
// pill on whatever happened to be biggest.
check("a Finder window is not a call",
      !ScreenPreset.isConferenceWindow(
        WindowInfo(bundleID: "com.apple.finder", appName: "Finder", title: "Downloads",
                   frame: Rect(x: 0, y: 0, width: 1200, height: 800), isOnScreen: true)),
      breaksIf: "the conference classifier is bypassed")
check("a Zoom control strip is too small to be the meeting",
      !ScreenPreset.isConferenceWindow(
        WindowInfo(bundleID: "us.zoom.xos", appName: "zoom.us", title: "Zoom",
                   frame: Rect(x: 0, y: 0, width: 180, height: 90), isOnScreen: true)),
      breaksIf: "the minimum window size is dropped")

// ============================================================== panel anchoring
section("a panel the host dragged is never moved back")

var a = PanelAnchor()
check("a fresh anchor may be positioned", a.mayReposition,
      breaksIf: "the latch starts engaged and automatic placement never runs")

// The first didMove arrives from the window server during creation, before we have
// placed anything. Latching on that would freeze every panel before it was shown.
a.noteObservedOrigin(PanelPoint(x: 10, y: 10))
check("a move before the first placement is not a drag", a.mayReposition,
      breaksIf: "creation-time didMove is read as the host dragging")

a.noteProgrammaticMove(to: PanelPoint(x: 100, y: 200))
a.noteObservedOrigin(PanelPoint(x: 100, y: 200))
check("our own placement is not a drag", a.mayReposition,
      breaksIf: "automatic re-anchoring is mistaken for a host drag — placement freezes after the first alarm")

// Sub-tolerance jitter from float rounding on setFrameOrigin.
a.noteProgrammaticMove(to: PanelPoint(x: 300, y: 400))
a.noteObservedOrigin(PanelPoint(x: 300.9, y: 399.4))
check("sub-pixel jitter is not a drag", a.mayReposition,
      breaksIf: "the tolerance is removed and rounding latches the panel")

// The real thing.
a.noteProgrammaticMove(to: PanelPoint(x: 300, y: 400))
let dragged = a.noteObservedOrigin(PanelPoint(x: 640, y: 380))
check("a real drag is detected", dragged,
      breaksIf: "the comparison is against a fixed anchor rather than the last origin we set")
check("a dragged panel is never repositioned again", !a.mayReposition,
      breaksIf: "the latch does not hold")

// The latch is permanent for the life of the panel. A later automatic placement must
// not clear it — that is precisely the snap-back this rule exists to stop.
a.noteProgrammaticMove(to: PanelPoint(x: 100, y: 100))
a.noteObservedOrigin(PanelPoint(x: 100, y: 100))
check("a subsequent programmatic move does not un-latch it", !a.mayReposition,
      breaksIf: "userMoved is recomputed per move instead of latching")

// Two panels are independent: dragging the pill must not pin the pre-call banner.
var pillAnchor = PanelAnchor()
var bannerAnchor = PanelAnchor()
pillAnchor.noteProgrammaticMove(to: PanelPoint(x: 0, y: 0))
pillAnchor.noteObservedOrigin(PanelPoint(x: 500, y: 500))
check("dragging one panel leaves the other free",
      !pillAnchor.mayReposition && bannerAnchor.mayReposition,
      breaksIf: "the latch is shared state instead of per-panel")

// A drag of exactly the tolerance is not a drag; one point past it is. Named so the
// boundary is measured rather than assumed.
var b = PanelAnchor()
b.noteProgrammaticMove(to: PanelPoint(x: 0, y: 0))
b.noteObservedOrigin(PanelPoint(x: PanelAnchor.tolerance, y: 0))
check("a move of exactly the tolerance is not a drag", b.mayReposition,
      breaksIf: "the comparison is >= instead of >")
var c = PanelAnchor()
c.noteProgrammaticMove(to: PanelPoint(x: 0, y: 0))
c.noteObservedOrigin(PanelPoint(x: PanelAnchor.tolerance + 1, y: 0))
check("a move one point past the tolerance is a drag", !c.mayReposition,
      breaksIf: "the tolerance swallows real drags")

// ------------------------------------------------------------------------ verdict
print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("meeting-presence-check FAILED")
    exit(1)
}
print("meeting-presence-check OK")
