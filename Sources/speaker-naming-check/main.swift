// Runnable verification for SpeakerNaming — `swift run speaker-naming-check`.
// Exits 0 if every case passes, 1 (with the failing case) otherwise. No XCTest /
// swift-testing dependency, so it runs under the Command Line Tools alone.
import Foundation
import SpeakerNaming

var failures = 0
@MainActor func check(_ name: String, _ cond: Bool) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)"); failures += 1 }
}

// A realistic transcript: dual-track, two diarized remote speakers, host on
// the mic track, and a body line that mentions "Speaker 1" inside the spoken text
// (must NOT be renamed — proves anchored, slot-only replacement).
let sample = """
---
title: quarterly-sync
date: 2026-07-02
start: 17:05 +00:00
duration: 00:00:40
language: en
participants:
  - Host (host, mic)
  - Speaker 1 (remote)
  - Speaker 2 (remote)
source: mic+system
diarization: pyannote, 2 speakers
---

1   [00:00:04] Speaker 1: Hi everyone.
2   [00:00:15] Speaker 2: Thanks Daniel.
3   [00:00:25] Host: I think Speaker 1 was right about that.
4   [00:00:27] Speaker 1: Let us move the deadline to Friday.
"""

check("detect finds remote speakers in order",
      SpeakerNaming.detect(in: sample) == ["Speaker 1", "Speaker 2"])

let renamed = SpeakerNaming.apply(["Speaker 1": "Daniel", "Speaker 2": "Samantha"], to: sample)
check("renames frontmatter participant lines",
      renamed.contains("  - Daniel (remote)") && renamed.contains("  - Samantha (remote)"))
check("renames body speaker slots",
      renamed.contains("1   [00:00:04] Daniel: Hi everyone.")
      && renamed.contains("2   [00:00:15] Samantha: Thanks Daniel.")
      && renamed.contains("4   [00:00:27] Daniel: Let us move the deadline to Friday."))
check("no stale Speaker token left in a slot",
      !renamed.contains("Speaker 1 (remote)") && !renamed.contains("] Speaker 1:"))

check("Speaker mention inside utterance text is untouched",
      SpeakerNaming.apply(["Speaker 1": "Daniel"], to: sample)
        .contains("3   [00:00:25] Host: I think Speaker 1 was right about that."))

check("host label (Host) is never renamed",
      SpeakerNaming.apply(["Host": "Somebody Else"], to: sample) == sample)

let partial = SpeakerNaming.apply(["Speaker 1": "Daniel", "Speaker 2": "   "], to: sample)
check("blank name leaves that speaker unchanged",
      partial.contains("  - Daniel (remote)")
      && partial.contains("  - Speaker 2 (remote)")
      && partial.contains("2   [00:00:15] Speaker 2: Thanks Daniel."))

check("name containing a colon is rejected",
      SpeakerNaming.apply(["Speaker 1": "Bad: Name"], to: sample) == sample)

check("no-op when no mapping applies",
      SpeakerNaming.apply([:], to: sample) == sample
      && SpeakerNaming.apply(["Speaker 9": "Nobody"], to: sample) == sample)

let inPerson = """
---
title: standup
participants:
  - Host (host, mic)
source: mic
diarization: none (single remote track)
---

1   [00:00:06] Host: Okay, let's continue.
"""
check("in-person transcript has no renameable speakers",
      SpeakerNaming.detect(in: inPerson) == []
      && SpeakerNaming.apply(["Speaker 1": "X"], to: inPerson) == inPerson)

// mic-multi: an in-person meeting with the mic track diarized into two speakers.
// Frontmatter participants carry "(in-person)" instead of "(remote)" — both the
// participant lines and the body slots must still rename.
let micMulti = """
---
title: team-sync
participants:
  - Speaker 1 (in-person)
  - Speaker 2 (in-person)
source: mic-multi
diarization: pyannote, 2 speakers
---

1   [00:00:00] Speaker 1: Nagyon jól.
2   [00:00:11] Speaker 2: Értem, köszönöm.
"""
check("mic-multi detects both in-person speakers",
      SpeakerNaming.detect(in: micMulti) == ["Speaker 1", "Speaker 2"])
let micRenamed = SpeakerNaming.apply(["Speaker 1": "Dana", "Speaker 2": "Jordan"], to: micMulti)
check("mic-multi renames in-person frontmatter + body",
      micRenamed.contains("  - Dana (in-person)")
      && micRenamed.contains("  - Jordan (in-person)")
      && micRenamed.contains("1   [00:00:00] Dana: Nagyon jól.")
      && micRenamed.contains("2   [00:00:11] Jordan: Értem, köszönöm.")
      && !micRenamed.contains("Speaker 1 (in-person)")
      && !micRenamed.contains("] Speaker 2:"))

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
if failures > 0 { exit(1) }
