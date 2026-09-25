# AGENTS.md: set up the notetaker

You are a coding agent setting this repository up for a person. At the end, every meeting they record on this Mac becomes a Markdown transcript in a folder their AI can read. Transcription runs on ElevenLabs with the person's own key and credits.

Follow the steps in order. Each has a command and the output to expect. Stop at the first step whose output does not match, and tell the person what you saw.

Steps marked **HUMAN:** are done by the person, not by you. Ask them to do it, wait, then check the result with the command given. Never type their API key, never run `--consent-upload`, and never approve a paid step for them. `--consent-upload` refuses when stdin is not a terminal. That stops a plain non-interactive shell, not an agent that has a pseudo-terminal, so this rule is yours to keep.

Report results by pasting the output of the commands, never by summarising that something works.

## 1. Check the machine

```bash
sw_vers -productVersion
swift --version
```

Expect macOS 14.2 or later, and `Swift version 6` or later. If Swift is missing, **HUMAN:** install the Xcode Command Line Tools with `xcode-select --install`.

## 2. Build

```bash
swift build
```

Expect the last line `Build complete!`.

## 3. Run the offline checks

```bash
"$(swift build --show-bin-path)/transcribe-check"
```

Expect the last lines `=== N/N checks passed ===` and `OK`. This uses no key, no credits and no network. Its only socket is a stub server on 127.0.0.1.

## 4. Pick the transcripts folder

Ask the person where transcripts should go. It must be a folder their AI tools read. The default below is fine if they have no preference.

```bash
DIR="$HOME/Documents/MeetingCaptures"
mkdir -p "$DIR" && echo "$DIR"
```

Expect the folder path. Shell variables may not survive between your commands, and they never reach the person's terminal. From here on, write this path out literally wherever a step says `$DIR`, and give the person commands that use the absolute path of the clone's `.build/debug/` binaries.

## 5. HUMAN: grant the microphone

The grant belongs to the app the command runs from, usually the terminal. Ask the person to run this in their own terminal and click **Allow** when macOS asks. Give them the command with both paths already filled in, for example `/path/to/clone/.build/debug/meeting-capture --label smoke-test --source mic --seconds 6 --output-dir "$HOME/Documents/MeetingCaptures"`:

```bash
.build/debug/meeting-capture --label smoke-test --source mic --seconds 6 --output-dir "$DIR"
```

Expect `[meeting-capture] wrote .../manifest.json` near the end. Then check it yourself:

```bash
ls "$DIR/.work/"
```

Expect one folder named like `2026-01-02T03-04-05Z-ab12`. Delete it, it was only a test: `rm -rf "$DIR/.work/"*`.

## 6. HUMAN: grant Screen Recording

Recording the other side of a call needs Screen Recording. Ask the person to open **System Settings > Privacy & Security > Screen Recording**, turn it on for their terminal app, then quit and reopen that terminal. It only takes effect in a new terminal.

Check it in the new terminal (this records both sides for 6 seconds):

```bash
.build/debug/meeting-capture --label smoke-test --seconds 6 --output-dir "$DIR"
```

Expect `[meeting-capture] mic 6.0s, system 6.0s` (numbers close to 6). Then `rm -rf "$DIR/.work/"*`.

## 7. HUMAN: create the ElevenLabs key

Ask the person to sign in at elevenlabs.io, open the API keys page, and create a key. If the page offers permission settings, allow only Speech to Text. (A key restricted this way has not yet been tested live against `--doctor`. If the doctor fails on the key line, try an unrestricted key.) They keep the key to themselves for the next step.

Transcription is paid from their ElevenLabs credits. The measured rate is 20.19 credits per channel-minute on one Creator-tier account in 2026, and a two-track call bills both tracks. Their own rate may differ.

## 8. HUMAN: put the key in the Keychain

Ask the person to run this in their own terminal. It asks for the key, so the key never lands on the command line or in shell history:

```bash
security add-generic-password -s meeting-capture-elevenlabs -a "$USER" -w
```

Check that it is there and has the shape of an ElevenLabs key, without printing it:

```bash
K="$(security find-generic-password -s meeting-capture-elevenlabs -w)" && case "$K" in sk_*) echo "key present, ${#K} characters";; *) echo "key present but does not start with sk_, ${#K} characters";; esac || echo "no key in the Keychain"; unset K
```

Expect `key present, N characters`. The author's key was 51 characters, and one that is 20 or shorter is almost certainly not a key. If it does not start with `sk_`, the person pasted something else, often the key's name or its masked hint. Ask them to copy the full key again and store it with `security add-generic-password -U -s meeting-capture-elevenlabs -a "$USER" -w`, where `-U` replaces the wrong entry.

## 9. HUMAN: consent to uploads

This is the person's decision. Audio will leave the machine. Ask them to run this in their own terminal and read the text it prints:

```bash
.build/debug/meeting-transcribe --consent-upload
```

It states where the audio goes (the ElevenLabs US endpoint), that ElevenLabs retains it (this tool never requests zero-retention), where the Data Processing Addendum is, the cost, and their duty to tell every participant that a meeting is recorded and transcribed. Running it records consent. Expect `consent recorded in .../consent`.

Do not run this command yourself, even if your shell has a terminal. It refuses when stdin is not a terminal, but that check cannot tell a person from a program.

## 10. Install the background worker

```bash
.build/debug/meeting-transcribe --install-worker --output-dir "$DIR"
```

Expect the last line to start with `loaded gui/<uid>/io.github.meeting-capture.transcribe-worker`. If you see `DRY RUN. Nothing was installed`, step 9 has not been done.

## 11. Run the doctor

```bash
.build/debug/meeting-transcribe --doctor
```

This records 3 seconds from the microphone and the system to check the grants, then deletes the recording. Expect every line to start with `PASS`, and the last line `DOCTOR: all checks passed`. A `FAIL` line says what to do. Paste the whole output to the person.

## 12. HUMAN: approve the paid live check

This sends about 5 seconds of synthesised speech to ElevenLabs and spends credits. Ask the person before running it.

```bash
.build/debug/meeting-transcribe --doctor --live
```

Expect `PASS  live: a 5 s round trip came back with the word "pineapple"` and `DOCTOR: all checks passed`.

## 13. Record a real meeting

Tell the person to wear headphones on calls. On speakers the microphone also picks up the other side, and their words appear twice in the transcript.

For a video call:

```bash
.build/debug/meeting-capture --label weekly-sync --output-dir "$DIR"
```

Press Enter or Ctrl-C to stop. For an in-person meeting with several people, add `--source mic-multi --speakers <n>`. For a call with one person on the far side, add `--speakers 1`, which keeps one voice from being split into two.

Do not pass `--transcriber`. The worker picks the recording up on its own.

## 14. Check the transcript arrived

```bash
.build/debug/meeting-transcribe --status "$DIR"
ls "$DIR"/*.md
```

While it works, `--status` shows the take as `pending` or `claimed`. When it is done the take disappears from `--status` and a file named `<label>_<meeting-id>.md` is in the folder. With an earlier uploader on the same provider, recordings of 41 to 261 minutes came back in 2 to 6 minutes. This kit's own worker has been timed only on sub-minute takes, which took a few seconds.

## If something goes wrong

- `--status` shows `PAUSED: <reason>`: the key, the balance or the consent needs attention. Fix the reason, then `.build/debug/meeting-transcribe --resume "$DIR"`.
- `--status` shows `failed .upload-failed` or another marker: the audio is kept. Fix the cause, then run the `--requeue` command it prints.
- The worker log is `~/Library/Logs/meeting-capture-transcribe.log`.
- To remove the worker: `.build/debug/meeting-transcribe --uninstall-worker`. Add `--revoke-consent` to withdraw consent too.

The transcript format is described in `TRANSCRIPT.md`. The full contract, including exit codes, is in `README.md`.
