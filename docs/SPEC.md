# SPEC — vadic: local dictation for macOS

Status: **Phase 1 implemented** (R1–R7, R11, R12); R8–R10 are next, each with its own spec
Date: 2026-10-05 · Target: Mac M1, macOS 14.2+ · Language: Swift (AppKit + AVFoundation), SPM

---

## 1. Why

VoiceInk is installed and used daily, but we want our own tool for three reasons:

1. **Inserting into any focused field** must be under our control, including when the clipboard
   is busy and must not be touched.
2. **Calls come next**: recording meetings without a bot in the call. The API for that is Apple's and
   lives only in Swift/ObjC, which is what decides the language.
3. **Our own vocabulary** (Structurizr, Qdrant, dependency-cruiser, Herdr…) must always apply,
   not depend on another app's settings.

---

## 2. Decisions (with reasons)

| Decision | Why |
|---|---|
| macOS + Swift, SPM | Menu bar, overlay, Accessibility and call-audio capture are native APIs; from Go only through cgo |
| Engine: `whisper.cpp` (Homebrew) | MIT, runs on the M1 GPU through Metal |
| Keep `whisper-server` running | Loading `large-v3-turbo` costs more than transcribing a phrase; the CLI pays that on every phrase |
| Models are downloaded on first launch; `whisper.cpp` comes from Homebrew | A 574 MB model inside the bundle would weigh down every rebuild. A model VoiceInk already downloaded is reused. Embedding libwhisper in-process like VoiceInk is an architecture change with no quality gain |
| Peak-normalize the recording before recognition (−0.1 dBFS) | The microphone records quietly (peaks −13…−24 dBFS) and Whisper drops quiet words and whole phrases (measured in §4). VoiceInk does the same |
| Prompt = style sentence + vocabulary | The sentence ("Здравствуйте, как ваши дела? Приятно познакомиться.", as in VoiceInk) brings punctuation, capitals and "ё"; the terms keep their spelling. The sentence alone loses terms, the vocabulary alone loses punctuation |
| Insert by typing Unicode keystrokes (`type`), Cmd+V as the fallback mode | Leaves the clipboard alone and works in every app; writing `AXValue` was dropped because some apps ignore it |
| Native UI only | No webviews at all |
| The Go prototype was dropped | Not because of the language itself but because of Phase 4 and the native UI APIs; its pipeline was carried over |

**Licenses.** MIT/Apache only: `whisper.cpp` (MIT), `ufal/whisper_streaming` (MIT), `parakeet-mlx` (Apache-2.0).
VoiceInk is GPL-3.0: none of its code is copied in any form, only ideas.

---

## 3. Verified facts

- `whisper.cpp`: ★54k, MIT, active. Homebrew formula `whisper-cpp` (1.9.2 on the dev machine), depends on `ggml`.
- Binaries: **`whisper-cli`, `whisper-server`, `whisper-stream`**.
- `whisper-cli` accepts **only 16-bit WAV**, so we record 16 kHz mono s16 PCM directly, with no conversion step.
- On Apple Silicon inference runs **on the GPU through Metal**.
- `whisper-stream` is real-time: samples every half second, `--step` / `--length` (README example: `--step 500 --length 5000`).
- Call-audio capture: **`CATapDescription` + `AudioHardwareCreateProcessTap`**, macOS 14.2+, needs the
  "System Audio Recording" permission.
- Reference for streaming recognition: `ufal/whisper_streaming` ★3673, MIT (LocalAgreement policy).
- Parakeet on the Apple GPU: `senstella/parakeet-mlx` ★986, Apache-2.0.
- Models: `ggml-large-v3-turbo-q5_0.bin` (574 041 195 bytes, SHA-256 `394221709cd5…ffa7e2`) and
  `ggml-silero-v5.1.2.bin` (885 098 bytes, SHA-256 `29940d98d42b…4ea2cf`) on HuggingFace.

---

## 4. Verified on real runs

- **Pipeline** "WAV 16 kHz mono s16 → `whisper-server` → text" works. The server may split a word across
  segments (`dependency-cru\niser`), so segments are joined without a separator.
- **Vocabulary (R4)** on a real `whisper-server`: with the prompt, "dependency-cruiser" and "Qdrant" are spelled
  right; without it they come out as "гдрент" and "dependency cru iser". Test `testVocabularyOnRealServer` (`VADIC_IT=1`).
- **VAD** removes made-up text on noise without speech: keyboard clicks without VAD → "Продолжение следует..."
  ("To be continued..."), with VAD → nothing.
- **Quality versus VoiceInk (2026-10-05).** 12 real dictations from the history, 10–52 s, peaks −13…−24 dBFS,
  `large-v3-turbo-q5_0` + VAD. Variants: as before (vocabulary, no normalization) / with normalization / like VoiceInk
  (style sentence, temperature 0.2, normalization) / style sentence + vocabulary + normalization, temperature 0.
  - Normalization brings back what was lost: "дали записи … допустим, 20" → "Да, удали записи. И согласен, надо
    поставить лимит, но пусть он будет 20 минут." ("yes, delete the recordings, and set the limit to 20 minutes");
    "нажимаем на my command" → "нажимаем на правый Command" ("right Command"); the phrase
    "Надо понять мне, как это работает" disappeared entirely without normalization.
  - The style sentence brings punctuation, capitals and "ё", but no lost words.
  - The last variant is as good as VoiceInk on live speech and keeps the terms on the reference phrase
    ("Открываю Structurizr и Qdrant, потом смотрю dependency-cruiser"), where the VoiceInk variant gives
    "строк чуризр и ГДРЕНТ… Депенденси Крузер". It was adopted. Temperature 0 and 0.2 differ within noise; 0 is kept.
- **VoiceInk 1.74 (built from source)**: same model, libwhisper in-process, greedy, temperature 0.2, `no_context`,
  VAD, peak normalization, prompt is only the style sentence (the vocabulary never reaches Whisper); after recognition
  it strips any `[…]`/`(…)`/`{…}` and filler words, splits into paragraphs and appends a trailing space.
  We took normalization, the style sentence and the trailing space; not paragraphs or bracket stripping (they get in
  the way when pasting into a chat and delete brackets the user dictated).

---

## 5. Requirements and acceptance criteria

| # | Requirement | Acceptance criterion |
|---|---|---|
| R1 | Insert into any focused field | Text appears in TextEdit, a browser, Telegram Desktop, VS Code and a terminal |
| R2 | Push-to-talk: hold the key to record, release to insert | Works by holding; an accidental short press without speech inserts **nothing** and leaves no garbage |
| R3 | State indication | Idle / recording / processing are visible. While recording a timer runs: in the overlay (`overlay: true`, default; the menu-bar icon steps aside and macOS shows its own microphone indicator) or as a red menu-bar icon with a timer (`overlay: false`) |
| R4 | Vocabulary | With the prompt on a live `whisper-server`, the phrase "…смотрю dependency-cruiser" is recognized with the term spelled right |
| R5 | Config in Application Support | The file is read and written; missing keys fall back to defaults. The server is local only, there are no access keys |
| R6 | History | Every dictation gets its own folder with audio and text; keeping audio can be switched off |
| R7 | Permissions | On launch the app checks Microphone and Accessibility itself and explains what is missing |
| R8 | Phase 2: progressive display | While speaking, the text grows in the overlay; nothing is written into the field until the key is released |
| R9 | Phase 3: progressive insertion | Only the stable prefix is typed into the field; what is already written is never rewritten |
| R10 | Phase 4: calls | Microphone and call audio are recorded as separate channels; the output is a meeting folder with a transcript and speaker labels |
| R11 | First launch | If the Whisper and VAD models are missing from `Models/`, they are downloaded from HuggingFace with progress in the menu and the overlay; a file gets its final name only after its SHA-256 matches. A model VoiceInk already downloaded is used without downloading. Without `whisper-cpp` the error says `brew install whisper-cpp` |
| R12 | Recognition quality | The recording is peak-normalized before recognition; the prompt is the style sentence + vocabulary; a space is appended after the inserted text (except in Return mode) |

R1–R7, R11 and R12 are the first working version. R8–R10 are next steps, each with its own spec. R10: see `docs/SPEC-meetings.md`.

---

## 6. Architecture and contracts

```
Vadic.app  (NSStatusItem, activationPolicy .accessory: no Dock icon)
├── Recorder      AVAudioRecorder → 16 kHz / mono / s16 WAV; level metering
├── Normalizer    peak normalization of the WAV before recognition
├── Engine        whisper-server (multipart) → whisper-cli fallback
├── Models        model and VAD download on first launch, SHA-256 check
├── Inserter      type | paste | clipboard
├── Hotkey        NSEvent global monitor, holding a modifier (push-to-talk)
├── Muter         mutes system output while recording
├── StatusUI      state icons + menu
├── Overlay       NSPanel: borderless, floating, non-activating, ignores the mouse
├── Config        JSON in Application Support
└── Store         history: audio.wav + text.txt + meta.json
```

Key contracts:

- **Recorder.start/stop** → path to a WAV or an error. An empty or silent recording is an error, not text.
- **Engine.transcribe(file) → text**. An error must carry its cause (server/CLI); "it just didn't work" is
  forbidden, otherwise failures are silent.
- **Inserter.insert(text) → success/error**. `paste` mode restores the previous clipboard.
- **State**: one per app, idle → recording → processing → idle. Overlapping recordings are impossible.

---

## 7. Non-goals of the first version

- A settings window: edit the JSON.
- Cloud recognition engines and summaries.
- A model manager (choosing and switching models in the UI; a fixed model + VAD pair downloads itself), auto-update, telemetry.
- Cross-platform support.
- VoiceInk code (GPL) or any GPL code as a base.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| No Accessibility permission → keystrokes silently go nowhere | Self-check on launch: warn right away and offer an "Open System Settings" button |
| The user switches apps while speaking | Insert where the focus is **at insertion time**; the text is saved in the history anyway |
| `whisper-server` crashed | Fall back to `whisper-cli` (slower because of model loading) and show the reason |
| The app runs without a bundle | macOS won't grant the microphone → always build a `.app` with `Info.plist` |
| The progressive stream "jitters" at phrase boundaries | Separate Phase 2 spec: show in the overlay first, only the final text goes into the field |
| Ad-hoc signing changes the cdhash on every build and macOS forgets permissions | The designated requirement is pinned to the bundle id |

---

## 9. Plan

- [x] Phase 1: R1–R7 on the Mac
- [x] R11: first-launch model download
- [x] R12: recognition quality (normalization, prompt, trailing space)
- [x] Spec for Phase 4 (`docs/SPEC-meetings.md`)
- [ ] Phase 4: call-audio capture through a Core Audio process tap
- [ ] Phase 2: overlay with progressive display
- [ ] Phase 3: progressive insertion by stable prefix

---

## 10. Decisions on the former open questions

1. **Model**: `large-v3-turbo-q5_0`, about 2–3 s per phrase on M1 including server warm-up.
2. **Hotkey**: holding a right-side modifier; right Option by default, configurable (`rightCommand`, `rightControl`, `fn`).
3. **Audio storage**: kept for 1 day (`audioRetentionDays`), text for 30 days (`historyRetentionDays`).
4. **Project location**: this repository.
5. **Order**: Phase 4 (calls) next; its spec is written.
6. **Go prototype**: not part of this repository.

---

## 11. Code status

Swift package in this repository: `VadicCore` (logic without UI, covered by tests) and `Vadic` (AppKit layer).
`swift test` runs the unit tests; `VADIC_IT=1` adds the tests against a real `whisper-server` and HuggingFace.
`scripts/build-app.sh` builds `build/Vadic.app`. CI runs on every push to `master`; pushing a `v*` tag publishes a release.

---

## 12. Backlog (ideas, deferred)

### B1. Pause media while recording instead of muting

Today system output is muted while recording (`muteWhileRecording`): YouTube keeps playing silently.
Better: pause the player and resume it after the key is released.

- **Knowing what plays.** Since macOS 15.4 MediaRemote is closed to third-party apps. The workaround is
  [`ungive/mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause): it reaches MediaRemote
  through `/usr/bin/perl`, which has the entitlement. Ready-made CLI: `brew install media-control`
  (`get` → JSON with `playing`, `pause`, `play`). VoiceInk does this (the idea, not the code: theirs is GPL).
- **Rules.** Pause only if `playing == true`. Resume only if we paused it and the player is still paused. Never send the
  Play/Pause media key blindly: if nothing was playing, it starts Music.
- **Pitfall (VoiceInk `af772a8`).** Pause and resume are asynchronous, so quick repeated presses race: a delayed resume
  from the previous recording fires in the middle of the next one. Needs a recording-session id and a re-read of the
  player state after the delay.
- **Fallback.** If `media-control` is missing or doesn't answer, the current mute.
- **Acceptance.** YouTube plays → press the hotkey → the video pauses → release → the video continues.
  Nothing was playing → nothing starts after the recording.
