# SPEC — vadic: meeting recording (Phase 4)

Status: **draft**, decisions agreed; the measurements in §8 come before any code
Date: 2026-10-05 · Based on: `docs/SPEC.md`, requirement R10

---

## 1. Why

Record calls (Zoom, Meet, Telegram, anything) without a bot in the call and get a meeting folder with a
transcript that shows who is speaking: me or the other side. Everything local, with the same engine as dictation.

---

## 2. Decisions

| Decision | Why |
|---|---|
| A module inside Vadic, not a separate app | Shared engine, `whisper-server`, menu bar, config, permissions and history; dictation code barely changes |
| Source: **all system audio except Vadic itself** | Catches any call without a list of apps. Cost: unrelated sound (music, notifications) ends up in the recording too |
| Microphone in the left channel, system audio in the right | `whisper --diarize` labels speakers by channel for free: left = "Me", right = "Them" |
| Capture through an aggregate device: microphone + process tap, with drift compensation | One stream with synchronized channels; the microphone and the output run on different clocks that drift apart over an hour |
| Start and stop manually from the menu | Detecting a call automatically is a separate problem, not needed in v1 |
| Transcribe after the meeting in a separate `whisper-cli` process | `whisper-server` handles one request at a time; an hour of audio would block dictation for minutes |
| Echo: v1 needs headphones and warns when speakers are in use | Without headphones the microphone hears the other side, they land in both channels and the transcript duplicates |
| Meeting audio is compressed to AAC | An hour of stereo WAV ≈ 230 MB, AAC 64 kbit/s ≈ 29 MB. Compression didn't pay off for dictation, here it does |
| Only "Me / Them" is distinguished | Telling several remote speakers apart needs a separate diarization model, out of v1 |
| Participants' consent is the user's responsibility | Vadic doesn't notify participants itself; it reminds the user at start |

---

## 3. Verified facts (2026-10-05, dev Mac: M1, macOS 26.6, whisper.cpp 1.9.2)

- **The capture API is in the SDK.** `AudioHardwareCreateProcessTap` + `CATapDescription` (macOS 14.2+), including
  `initStereoGlobalTapButExcludeProcesses:` / `initMonoGlobalTapButExcludeProcesses:`: all audio except the given
  processes. macOS 26 adds `bundleIDs` and `processRestoreEnabled`.
- **Permission**: "System Audio Recording", key `NSAudioCaptureUsageDescription` in `Info.plist`.
- **Stereo diarization works.** `whisper-cli --diarize` on a 16 kHz s16 stereo WAV (phrase A in the left channel,
  phrase B in the right) returned:
  ```
  [00:00:00.000 --> 00:00:03.220]  (speaker 0) Привет, это я. Давай обсудим план на неделю.
  [00:00:04.520 --> 00:00:08.200]  (speaker 1) Хорошо, начнем с релиза. Он запланирован на пятницу.
  ```
  `speaker 0` = left channel, `speaker 1` = right. `whisper-server` has the flag too.
- **Speed.** 9.6 min mono (≈4 min of speech + pauses), `large-v3-turbo-q5_0` + VAD, `whisper-cli`: **25 s**.
  Estimate: around 6 min per hour of dense speech. Synthetic; not measured on a live call.
- **Quality on long recordings is in question.** In the same run, one of 40 repetitions of a phrase lost part of it.
  Needs measuring on a live recording (§8).

---

## 4. Requirements and acceptance criteria

| # | Requirement | Acceptance criterion |
|---|---|---|
| M1 | Start/stop from the menu | "Start Meeting Recording" / "Stop Meeting Recording (0:42:13)"; choosing it again stops |
| M2 | Two-channel recording | 16 kHz s16 stereo WAV: left is the microphone, right is all system audio without Vadic's own sounds. In a silent call the right channel is quiet; when I speak, left is louder than right |
| M3 | Indication | While recording, the menu-bar icon is red with a timer regardless of `overlay`; the overlay doesn't show meetings (it would cover the screen for an hour) |
| M4 | Transcription after the meeting | After stopping: background `whisper-cli --diarize` + VAD + vocabulary (`prompt`) + replacements. The menu shows "Transcribing meeting…" |
| M5 | Dictation is unaffected | Dictation works during recording and transcription of a meeting; its latency grows by at most 50% (measurement §8.3). Dictation doesn't mute output while a meeting is recording |
| M6 | Meeting folder | `Meetings/<timestamp>/`: `audio.m4a` (AAC stereo), `transcript.md`, `meta.json`. The WAV is deleted only after transcription and compression succeed |
| M7 | Transcript format | `transcript.md`: lines `[00:12:03] **Me:** …` / `[00:12:09] **Them:** …`; consecutive lines of one speaker are merged; an undetermined speaker is `**?:**` |
| M8 | Headphones | If output goes to the built-in speakers at start, warn "Use headphones, otherwise the other side ends up in your channel"; recording can start anyway |
| M9 | Permission | "System Audio Recording" is requested when the first meeting starts, not at app launch; on refusal, an explanation and a button to System Settings, as in R7 |
| M10 | Disk protection | Starting is refused with less than 2 GB free. Auto-stop after `maxMeetingHours` (default 4), transcribed as usual |
| M11 | Retention | Meeting audio: `meetingAudioRetentionDays` (default 30); transcripts: forever (0 = forever). Separate from dictation |
| M12 | A crash doesn't lose the recording | If the app crashed mid-meeting, the next launch finds the unfinished recording, repairs it and offers to transcribe it |
| M13 | Consent reminder | At start, a one-line reminder to tell the participants; can be turned off in the config |

---

## 5. Architecture and contracts

```
Vadic.app
├── (dictation: unchanged except M5)
└── Meetings
    ├── MeetingRecorder    aggregate device = microphone + process tap (all output except Vadic);
    │                      one IOProc → stereo WAV (L = mic, R = system) in Meetings/<ts>/recording.wav
    ├── MeetingTranscriber whisper-cli --diarize --vad --prompt … → segments (time, speaker, text)
    │                      → replacements → transcript.md; AAC through afconvert
    └── MeetingStore       meeting folders, recovery of unfinished ones, retention
```

Contracts:

- **MeetingRecorder.start() → meeting folder or an error with its cause** (no permission, no disk space, tap not created).
  **stop() → WAV path and duration.** Tap/aggregate-device errors carry the `OSStatus`; "didn't work" is forbidden.
- **MeetingTranscriber.transcribe(wav) → segments**, cancellable; quitting the app stops the process (like `whisper-cli`
  in the engine). Runs at lowered priority (`taskpolicy -b` or equivalent).
- **Meeting state is independent of dictation state**: `idle → recording → transcribing → idle`. Two meetings are never
  recorded at once.
- **Config** (missing keys fall back to defaults): `maxMeetingHours: 4`, `meetingAudioRetentionDays: 30`,
  `meetingTranscriptRetentionDays: 0`, `consentReminder: true`.

---

## 6. Not in v1

- Summaries or any LLM on top of the transcript.
- Telling several remote speakers apart (needs a diarization model such as pyannote / sherpa-onnx).
- Auto-start when a call begins.
- Live transcription during the meeting.
- Choosing specific apps to record.
- Video.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| Echo through speakers: the other side in both channels, duplicated text | v1: headphones + warning (M8). Echo cancellation on the microphone (`AVAudioEngine` voice processing) after measurement §8.1 |
| Unrelated sound (music, notifications) ends up in the recording | Accepted deliberately (all output). VAD drops non-speech; notifications remain a risk |
| Microphone and output clocks drift | Aggregate device with drift compensation; measurement §8.5 |
| A crash mid-meeting leaves a WAV without a valid header | Repair from the data size on launch (M12) |
| Background transcription slows dictation down (shared GPU) | Lowered priority; measurement §8.3; if not enough, pause meeting transcription while dictating |
| Phrases dropped on long recordings | Measurement §8.6; if confirmed, cut the recording into chunks at VAD pauses |
| The JSON output format of `--diarize` is unknown | Check §8.4; fallback: parse the text output `[t --> t] (speaker N) …` |

---

## 8. Measurements before code

1. **Echo.** 5 min of a real call through speakers and through headphones: the share of the other side's lines that land in "Me".
2. **Speed.** A 60-min live call → `whisper-cli --diarize` transcription time on M1. Synthetic estimate: ~6 min.
3. **Dictation under load.** Dictation latency with and without background meeting transcription. Target: no worse than +50%.
4. **Diarize format.** Whether `-oj` / `-ojf` carries the speaker; otherwise settle on parsing the text output.
5. **Drift.** 60 min through the aggregate device: channel offset measured on a clap at the start and at the end.
6. **Drops on long recordings.** An hour of live speech: compare the transcript with a reference on 3–5 fragments.

---

## 9. Plan

- [ ] Measurements §8.2, §8.4, §8.6 on a manually recorded call
- [ ] Spike: process tap + aggregate device → stereo WAV (§8.5, checks M2)
- [ ] Measurements §8.1, §8.3
- [ ] Test cases (diarize parsing, merging lines, WAV repair, retention) → RED → GREEN
- [ ] M1–M13 on the Mac
