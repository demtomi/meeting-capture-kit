# Transcript format

`meeting-transcribe` writes one Markdown file per recording. It is built for an AI to read and cite: YAML frontmatter, then one utterance per line with its index, start time and speaker. Nothing is summarised, translated or rewritten.

This is `schema: 1` of the format. A change to any field or to the line shape bumps that number.

## File names

For an output directory `<dir>`:

| File | What it is |
|---|---|
| `<dir>/<slug>_<meeting_id>.md` | The transcript. |
| `<dir>/.raw/<slug>_<meeting_id>.json` | The speech-to-text responses the transcript was built from, one entry per track plus `_meta`. |

`<slug>` comes from the recording's label. Every character outside `A-Z a-z 0-9 . _ -` becomes `-`, leading dots and dashes are removed, and it is cut at 80 characters. An empty result is `meeting`. So a label cannot name a file outside `<dir>` and cannot produce a hidden file. `<meeting_id>` is the capture's UTC start stamp plus four hex characters, so two recordings never share a name.

## Shape

```
---
schema: 1
title: "weekly sync"
date: "2026-01-02"
start: "04:04 +01:00"
duration: "61m50s"
language: "eng"
participants:
  - "Alex Host (host, mic)"
  - "Speaker 1 (remote)"
  - "Speaker 2 (remote)"
source: "mic+system"
diarization: "elevenlabs, 3 speakers"
transcription:
  provider: "elevenlabs"
  model: "scribe_v2"
  endpoint_region: "us"
  retention: "provider-side, no zero-retention below Enterprise"
meeting_id: "2026-01-02T03-04-05Z-ab12"
---
1  [00:00:00] Alex Host: good morning
2  [00:00:00] Speaker 1: hi all
3  [00:00:01] Speaker 2: hey
```

## Frontmatter

| Key | Value |
|---|---|
| `schema` | The format version, `1`. |
| `title` | The recording's label, or `meeting` when it had none. |
| `date` | Local start date, `YYYY-MM-DD`. |
| `start` | Local start time and UTC offset, `HH:MM +HH:MM`. |
| `duration` | Length of the longest track, `<minutes>m<seconds>s`. |
| `language` | The language code the provider returned for the track with the most words, as returned. Speech is never translated. |
| `participants` | The host as `<name> (host, mic)`, remote speakers as `Speaker N (remote)`. On an in-person `mic-multi` recording every voice is `Speaker N (in-person)`. |
| `source` | `mic+system`, `mic` or `mic-multi`, from the capture. |
| `diarization` | Exactly one of the three values below. |
| `transcription` | Provider, model, endpoint region and retention. |
| `meeting_id` | The capture's meeting id. The deletion rule checks this value. |
| `silent_tracks` | Present only when a track held digital silence and was not uploaded. Lists the track names. A transcript with this key is one-sided on purpose. |

`diarization` is one of:

- `elevenlabs, <N> speakers`: at least one track was split into speakers by the provider. `N` counts every distinct speaker label in the transcript, the host included.
- `none (single remote track)`: a two-track call whose remote track was not split, because the capture said one person was on the far side, or because that track was silent.
- `none (in-person single track)`: a `mic` recording. All speech is the host.

## Body

- One utterance per line: `<n>  [HH:MM:SS] <Speaker>: <text>`. `<n>` starts at 1 and equals the line's position in the body. Two spaces follow it.
- `[HH:MM:SS]` is the utterance's start, counted from the start of the recording. Both tracks share one zero, so their lines interleave in time order.
- An utterance is a run of words by one speaker. A pause of more than 1.2 seconds starts a new line even when the speaker is unchanged. Long turns are not split at sentence boundaries.
- The host's line carries the name from the capture's `--host`. Remote and in-person speakers are `Speaker N`, numbered in the order of the provider's speaker ids. A name never contains a colon or a line break.
- Only spoken words appear. Sound events and spacing tokens from the provider are dropped. There is no Markdown bold and no list numbering.

## Known limits

- On speakers rather than headphones, the host's microphone also picks up the remote side, so remote speech appears twice: once as the remote speaker and once as the host. Use headphones.
- The provider can split one remote voice into two speakers. `meeting-transcribe` prints a warning for any speaker holding under 0.5% of a diarized track's words, and it does not merge them, because a brief real speaker looks the same.
- In-person `mic-multi` diarization on a single room microphone has not been measured.
