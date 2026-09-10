// Runnable verification for ScreenPreset — `swift run screen-record-check`.
// Exits 0 if every case passes, 1 (with the failing case) otherwise. No XCTest /
// swift-testing dependency, so it runs under the Command Line Tools alone.
//
// Everything here is decided on DATA, never on live system state: no
// ScreenCaptureKit, no AVFoundation, no TCC. That is the whole reason ScreenPreset
// is a library — a display picker that silently records the wrong screen, or a
// geometry that squeezes a portrait panel, is wrong in a way a compiler cannot see
// and must be replayable without a permission prompt.
//
// Two of these limbs exist because the defect was measured in a real run: the
// points-vs-pixels box, and `auto` resolving from an ordinary Slack window.
import Foundation
import ScreenPreset

var failures = 0
// @MainActor for the same reason as speaker-naming-check: top-level code is
// main-actor isolated under Swift 6, so a nonisolated helper cannot touch `failures`.
@MainActor func check(_ name: String, _ cond: Bool) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)"); failures += 1 }
}

// A three-display rig, in the geometry the window server actually reports. These are
// real measured values from one machine, kept because a synthetic set would not have
// produced the rotated portrait panel that broke the geometry once. Frames are POINTS (global
// coordinates); pixelWidth/pixelHeight are BACKING PIXELS. Keeping both in the
// fixture is deliberate: conflating them is the defect fitBox exists to prevent.
let builtin  = DisplayInfo(id: 1, pixelWidth: 3024, pixelHeight: 1964,
                           frame: Rect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
let external = DisplayInfo(id: 3, pixelWidth: 1920, pixelHeight: 1080,
                           frame: Rect(x: 1512, y: 0, width: 1920, height: 1080), isBuiltin: false)
let portrait = DisplayInfo(id: 2, pixelWidth: 1080, pixelHeight: 1920,
                           frame: Rect(x: 3432, y: 0, width: 1080, height: 1920), isBuiltin: false)
let desk = [builtin, external, portrait]

// MARK: - Geometry

// The retina built-in. Scaling from POINTS would have produced 1512x982 while every
// log line claimed 1080p. That defect, in numbers.
let b = ScreenPreset.fitBox(pixelWidth: 3024, pixelHeight: 1964, maxLong: 1920, maxShort: 1080)
check("retina built-in boxes to 1662x1080", b == (1662, 1080))
check("retina built-in is NOT the points-derived 1512x982", b != (1512, 982))

// A BOX, not a height cap. The height cap this replaced would give 607x1080 and
// throw away half the resolution that already fits.
let p = ScreenPreset.fitBox(pixelWidth: 1080, pixelHeight: 1920, maxLong: 1920, maxShort: 1080)
check("portrait 1080x1920 survives the box intact", p == (1080, 1920))

// NOT `p != (607, 1080)`. That named one specific wrong answer, and the height-cap
// mutation actually produces 606x1080 (even-rounding), so the limb passed while the
// defect was live. Assert the PROPERTY instead: aspect ratio is preserved, for every
// shape, which no height cap can satisfy on a portrait panel.
var ratioHeld = true
for (w, h) in [(3024, 1964), (1080, 1920), (1920, 1080), (2560, 1440), (1366, 768)] {
    let r = ScreenPreset.fitBox(pixelWidth: w, pixelHeight: h, maxLong: 1920, maxShort: 1080)
    // Cross-multiply within a one-pixel tolerance, since both edges round to even.
    let drift = abs(Double(r.width) / Double(r.height) - Double(w) / Double(h))
    if drift > 0.002 { ratioHeld = false }
}
check("aspect ratio is preserved across every display shape on the desk", ratioHeld)

check("1080p external passes through unchanged",
      ScreenPreset.fitBox(pixelWidth: 1920, pixelHeight: 1080, maxLong: 1920, maxShort: 1080) == (1920, 1080))
check("never upscales a small display",
      ScreenPreset.fitBox(pixelWidth: 800, pixelHeight: 600, maxLong: 1920, maxShort: 1080) == (800, 600))

// HEVC rejects odd dimensions, so the rounding must never emit one.
var alwaysEven = true
for w in stride(from: 1001, through: 4001, by: 250) {
    for h in stride(from: 777, through: 2777, by: 250) {
        let r = ScreenPreset.fitBox(pixelWidth: w, pixelHeight: h, maxLong: 1920, maxShort: 1080)
        if r.width % 2 != 0 || r.height % 2 != 0 { alwaysEven = false }
        if r.width < 2 || r.height < 2 { alwaysEven = false }
    }
}
check("every box dimension is even and >= 2 across a sweep", alwaysEven)
check("degenerate input degrades instead of trapping",
      ScreenPreset.fitBox(pixelWidth: 0, pixelHeight: 0, maxLong: 1920, maxShort: 1080) == (2, 2))

// MARK: - Conference-window detection

let zoomWin = WindowInfo(bundleID: "us.zoom.xos", appName: "zoom.us", title: "Zoom Meeting",
                         frame: Rect(x: 1600, y: 100, width: 1200, height: 800), isOnScreen: true)
// The defect this guards: an ordinary always-open Slack window is not a call. On a
// three-display rig this silently recorded the wrong screen for a whole meeting.
let slackOrdinary = WindowInfo(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                               title: "Slack | general | Acme",
                               frame: Rect(x: 1600, y: 100, width: 1400, height: 900), isOnScreen: true)
let slackHuddle = WindowInfo(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                             title: "Huddle in #general",
                             frame: Rect(x: 1600, y: 100, width: 900, height: 600), isOnScreen: true)
let tinyStrip = WindowInfo(bundleID: "us.zoom.xos", appName: "zoom.us", title: "Zoom Meeting",
                           frame: Rect(x: 1600, y: 100, width: 150, height: 60), isOnScreen: true)
let offscreen = WindowInfo(bundleID: "us.zoom.xos", appName: "zoom.us", title: "Zoom Meeting",
                           frame: Rect(x: 1600, y: 100, width: 1200, height: 800), isOnScreen: false)
let pricingTab = WindowInfo(bundleID: "com.google.Chrome", appName: "Chrome",
                            title: "Zoom pricing and plans",
                            frame: Rect(x: 1600, y: 100, width: 1200, height: 800), isOnScreen: true)

check("a Zoom meeting window is a call", ScreenPreset.isConferenceWindow(zoomWin))
check("an ordinary Slack window is NOT a call", !ScreenPreset.isConferenceWindow(slackOrdinary))
check("a Slack huddle IS a call", ScreenPreset.isConferenceWindow(slackHuddle))
check("a control strip is too small to be a call", !ScreenPreset.isConferenceWindow(tinyStrip))
check("an offscreen window is not a call", !ScreenPreset.isConferenceWindow(offscreen))
check("a browser tab about Zoom pricing is not a call", !ScreenPreset.isConferenceWindow(pricingTab))

// --- Google Meet. Every fixture below is a REAL window title, captured from a live call on
// 2026-08-06, positives and negatives alike, because the bug was that the rule matched a
// title nobody had ever looked at. The needles claimed to cover Meet and covered nothing.
func chrome(_ title: String, w: Double = 1920, h: Double = 1049) -> WindowInfo {
    WindowInfo(bundleID: "com.google.Chrome", appName: "Google Chrome", title: title,
               frame: Rect(x: 3432, y: -662, width: w, height: h), isOnScreen: true)
}

// The measured live call.
check("a live Google Meet call in Chrome is a call",
      ScreenPreset.isConferenceWindow(chrome("Meet – Weekly project sync")))
// Meet is not consistent about its dash across locales and versions, and accepting all
// three costs nothing.
check("Meet with a hyphen is a call",
      ScreenPreset.isConferenceWindow(chrome("Meet - Weekly project sync")))
check("Meet with an em dash is a call",
      ScreenPreset.isConferenceWindow(chrome("Meet — Weekly project sync")))

// THE NEGATIVE THAT FORCED A PREFIX. This exact window was open while the miss was being
// diagnosed. `contains("meet")` matches it, and classifying a notes document as the call
// puts the pill and the recording on the wrong display for the whole meeting — a worse
// failure than the miss it would fix.
check("a Meeting Notes document is NOT a call",
      !ScreenPreset.isConferenceWindow(chrome("Quarterly review | Meeting Notes | Acme")))
check("a Google Calendar week view is NOT a call",
      !ScreenPreset.isConferenceWindow(chrome("Alex Rivera – Calendar - Week of 3 August 2026")))
check("a YouTube video with a dash in the title is NOT a call",
      !ScreenPreset.isConferenceWindow(chrome("Ep 12 - How turbines work |…GY EXPLAINED - YouTube 🔊")))
// "meet" must lead the title, not merely appear at a word boundary somewhere in it.
check("a title that merely mentions a meeting is NOT a call",
      !ScreenPreset.isConferenceWindow(chrome("Notes from the meet - Tuesday")))
// The Meet landing page, where you have not joined anything yet. No dash, no call.
check("the Meet home page is NOT a call", !ScreenPreset.isConferenceWindow(chrome("Meet")))

// MARK: - Display resolution

func pick(_ c: DisplayChoice, _ d: [DisplayInfo], _ w: [WindowInfo]) -> DisplayPick? {
    ScreenPreset.resolveDisplay(choice: c, displays: d, windows: w)
}

let autoZoom = pick(.auto, desk, [zoomWin])
check("auto follows the call window to the external",
      autoZoom?.display.id == external.id && autoZoom?.how == "auto:zoom.us")

// The regression guard. If Slack ever returns to the bundle set, this flips.
let autoSlack = pick(.auto, desk, [slackOrdinary])
check("auto with only an ordinary Slack window falls back to built-in",
      autoSlack?.display.id == builtin.id && autoSlack?.how == "builtin")

check("auto with no windows at all falls back to built-in",
      pick(.auto, desk, [])?.display.id == builtin.id)

// Largest candidate wins, so a full-screen call beats a mini-window.
let big = WindowInfo(bundleID: "us.zoom.xos", appName: "zoom.us", title: "Zoom Meeting",
                     frame: Rect(x: 3500, y: 100, width: 1000, height: 1700), isOnScreen: true)
check("the LARGEST conference window decides, not the first",
      pick(.auto, desk, [zoomWin, big])?.display.id == portrait.id)

let explicitOK = pick(.explicit(3), desk, [])
check("an explicit display is honoured",
      explicitOK?.display.id == external.id && explicitOK?.how == "explicit")

// A remembered display that has since been unplugged must degrade to a real
// recording, never abort one.
let unplugged = pick(.explicit(999), desk, [])
check("an unplugged remembered display falls back to built-in",
      unplugged?.display.id == builtin.id && unplugged?.how == "fallback:unplugged")

let builtinChoice = pick(.builtin, desk, [])
check("builtin resolves to the built-in panel",
      builtinChoice?.display.id == builtin.id && builtinChoice?.how == "builtin")

// Clamshell: lid closed, no built-in in the list at all.
let clamshell = [external, portrait]
let clam = pick(.builtin, clamshell, [])
check("clamshell (no built-in present) falls back to the first display",
      clam?.display.id == external.id && clam?.how == "fallback:first")
check("auto in clamshell with no call window also lands on a real display",
      pick(.auto, clamshell, [])?.display.id == external.id)

check("no displays at all returns nil rather than a bogus pick",
      pick(.auto, [], [zoomWin]) == nil)

// MARK: - DisplayChoice parsing

check("parse builtin", DisplayChoice.parse("builtin") == .builtin)
check("parse auto", DisplayChoice.parse("auto") == .auto)
check("parse a numeric id", DisplayChoice.parse("3") == .explicit(3))
// A stale or corrupt remembered value must degrade to auto, never abort a take.
check("parse nil / empty / garbage degrades to auto",
      DisplayChoice.parse(nil) == .auto
      && DisplayChoice.parse("") == .auto
      && DisplayChoice.parse("not-a-display") == .auto
      && DisplayChoice.parse("-4") == .auto)

// MARK: - Disk preflight

// Refusing the VIDEO is always acceptable. The caller must never let this refuse
// the audio recording, which is why it returns a verdict rather than exiting.
let threeHours = 3 * 3600
let bitrate = 2_500_000
let needed = ScreenPreset.estimatedBytesPerSecond(bitrate: bitrate) * threeHours
check("bytes-per-second is bitrate/8", ScreenPreset.estimatedBytesPerSecond(bitrate: bitrate) == 312_500)

check("ample disk is ok",
      ScreenPreset.checkSpace(freeBytes: 200_000_000_000, bitrate: bitrate,
                              plannedSeconds: threeHours, floorBytes: 5_000_000_000) == .ok)

// Exactly at the boundary: need == free must pass, because the floor is already
// the reserve. An off-by-one here refuses a recording that fits.
check("exactly enough disk is ok, not refused",
      ScreenPreset.checkSpace(freeBytes: needed + 5_000_000_000, bitrate: bitrate,
                              plannedSeconds: threeHours, floorBytes: 5_000_000_000) == .ok)

check("one byte short refuses",
      ScreenPreset.checkSpace(freeBytes: needed + 5_000_000_000 - 1, bitrate: bitrate,
                              plannedSeconds: threeHours, floorBytes: 5_000_000_000)
      != .ok)

// The refusal has to carry BOTH numbers, or the message cannot say what to free up.
if case let .refuse(freeMB, needMB) = ScreenPreset.checkSpace(
        freeBytes: 1_000_000_000, bitrate: bitrate,
        plannedSeconds: threeHours, floorBytes: 5_000_000_000) {
    check("refusal reports free MB", freeMB == 1_000_000_000 / 1_048_576)
    check("refusal reports needed MB", needMB == (needed + 5_000_000_000) / 1_048_576)
    check("refusal needs more than it has", needMB > freeMB)
} else {
    check("a full disk refuses", false)
}

// MARK: - Sidecar

// The sidecar is the completeness sentinel: meeting-screen writes it LAST and
// atomically, so its presence is what tells the app the .mov is playable.
let sidecar = ScreenPreset.Sidecar(
    id: "abc-123", label: "kickoff", startedAt: "2026-08-03T21:00:00+02:00",
    displayID: 1, displayHow: "builtin", width: 1662, height: 1080, fps: 15,
    codec: "hevc", durationSeconds: 19.95, bytes: 505_627,
    framesWritten: 297, framesSkippedUnchanged: 64, framesDropped: 0,
    truncatedReason: nil)

guard let encoded = try? sidecar.encoded(),
      let text = String(data: encoded, encoding: .utf8) else {
    check("sidecar encodes", false)
    print("\n\(failures) check(s) FAILED.")
    exit(1)
}
check("sidecar encodes", true)
check("sidecar carries a schema version", text.contains("\"schema\" : 1"))

// NOT a two-key sample. `bytes` before `codec` happened to hold under the UNSORTED
// encoder about half the time, so that limb reported a pass while the defect was
// live — flaky, which reads exactly like working. Assert the whole key sequence is
// ascending: under .sortedKeys that is always true, and without it 16 keys landing
// in perfect order by chance is not a thing that happens.
let emittedKeys = text
    .split(whereSeparator: \.isNewline)
    .compactMap { line -> String? in
        guard let open = line.firstIndex(of: "\""),
              let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: open)..<close])
    }
check("sidecar emits every key it was given", emittedKeys.count >= 15)
check("sidecar keys are in ascending order (byte-stable across runs)",
      emittedKeys == emittedKeys.sorted())
// A clean take must not claim it was truncated.
check("a nil truncatedReason is omitted, not rendered null",
      !text.contains("truncatedReason"))

let truncated = ScreenPreset.Sidecar(
    id: "abc-123", label: "kickoff", startedAt: "2026-08-03T21:00:00+02:00",
    displayID: 1, displayHow: "builtin", width: 1662, height: 1080, fps: 15,
    codec: "hevc", durationSeconds: 19.95, bytes: 505_627,
    framesWritten: 297, framesSkippedUnchanged: 64, framesDropped: 0,
    truncatedReason: "disk below floor (900 MB free)")
let truncText = String(data: (try? truncated.encoded()) ?? Data(), encoding: .utf8) ?? ""
check("a truncated take SAYS it was truncated", truncText.contains("disk below floor"))

// Round-trip: the app reads this back, so a field that encodes but does not decode
// would surface as a missing recording rather than as a parse error.
if let d = try? JSONDecoder().decode(ScreenPreset.Sidecar.self, from: encoded) {
    check("sidecar round-trips unchanged", d == sidecar)
} else {
    check("sidecar round-trips unchanged", false)
}

// The frame accounting must reconcile: written + skipped is what the stream
// delivered, and dropped frames are lost ones. A sidecar that cannot be checked
// against the container is not evidence.
check("frame accounting fields are all present and non-negative",
      sidecar.framesWritten >= 0 && sidecar.framesSkippedUnchanged >= 0 && sidecar.framesDropped >= 0)

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
if failures > 0 { exit(1) }
