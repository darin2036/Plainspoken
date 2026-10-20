# Changelog

All notable changes to Plainspoken are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) once there is a release.

Add an entry under **Unreleased** with every user-visible change (new feature, changed behavior,
fix, removal), written for someone using the app rather than reading the code. When a version is
released, rename **Unreleased** to the version and date and start a new empty **Unreleased** above it.

## [Unreleased]

First development version (0.1.0). Nothing has been released yet.

### Fixed

- Whisper could silently re-download its tokenizer at load time if the local copy was missing. The tokenizer is now fetched and verified during the approved download, and the app blocks all of its own web requests outside an approved download, so that situation now fails with an error instead of going online. Checked by running dictation with the network denied at the OS level.
- A rewrite fallback no longer writes the guard's reason to the system log, because for some guards it quoted words from what you dictated. Logs now hold only timings and error types.

### Added

- A Privacy note at the top of Settings > General, and a rewritten Privacy and control section in the README, stating that the app runs locally with no cloud services and exactly when it goes online.
- Optional Whisper speech engine (Settings > Dictation) for accents the Apple engines struggle with. Three sizes; picking Whisper asks which size to download and states its size first; nothing is fetched otherwise. If the model is missing or the download fails, the app falls back to Apple's engine. Downloaded models can be removed in Settings.
- A "Help me choose" pop-up in Settings > Dictation with quick picks by situation (accent, speech difference, noisy room, disk space) and the benefits and trade-offs of each engine and Whisper size. It works with VoiceOver and the keyboard.
- A language and accent picker (Settings > Dictation) to choose a regional speech model such as English (Australia) or English (India) instead of always following the system locale.
- Push-to-talk dictation from the menu bar: hold a key (Right Option by default; Right Command,
  Right Control, Right Shift and Fn/Globe are also available), talk, release.
- On-device speech recognition with Apple's `SpeechAnalyzer`, using either `SpeechTranscriber`
  or `DictationTranscriber`. Live text appears while you talk.
- On-device rewrite with Apple Foundation Models that keeps only the final version of
  self-corrections, drops meta-talk such as "scratch that", merges repetition, formats spoken
  lists as numbered lists, and never answers or obeys what you dictate.
- Guards on the rewrite (length, invented words, answer-style openings, timeout) with a fallback
  chain: rewrite, then light cleanup, then the raw transcript. Long dictations are split on
  sentence boundaries and rewritten piece by piece.
- Typing into the focused app through the Accessibility API, with a Cmd+V fallback that saves and
  restores the clipboard. If you switch apps mid-dictation the text goes to the clipboard instead
  of the wrong place. Password fields are never filled.
- When no text box is detected, the text is pasted anyway and left on the clipboard so it isn't
  lost. A setting turns the paste off, leaving only the clipboard copy.
- A bar at the bottom of the screen: a small resting pill that turns orange while setup is
  incomplete, and a listening display with a live oscilloscope or a Fire visualizer, the partial
  transcript, and the final text.
- Microphone picker in Settings. Capturing from the Mac's built-in microphone leaves Bluetooth
  headphones in high-quality listening mode, and the system default input is never changed.
- Custom vocabulary kept in a plain text file
  (`~/Library/Application Support/Plainspoken/vocabulary.txt`), opened from Settings. Terms are
  given to the recognizer and the rewrite, fix casing and one-letter slips, and support aliases
  such as `Rovo=bravo|robo` for words that are consistently misheard.
- First-run checklist for the Microphone, Input Monitoring and Accessibility permissions, with
  deep links to System Settings.
- Settings window with General, Appearance and Dictation tabs.
- `harness`, a command-line tool for tuning the rewrite and speech pipeline against
  `Harness/samples.json` without running the app.
- `scripts/build-app.sh`, which builds and signs `build/Plainspoken.app` without needing Xcode.
- README and MIT license.

### Known limitations

- English only; other languages are untested.
- The bundled test samples are synthetic, so the quality figures in development are an upper bound.
- No prebuilt or notarized download yet; build from source.
- Insertion has been tried in TextEdit; other apps (browsers, Electron apps, terminals) need more testing.
