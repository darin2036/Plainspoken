<div align="center">

# Plainspoken

**Say it the messy way. Get it written the clean way.**

Hold a key, talk the way you think, let go. Plainspoken types what you meant into whatever app you're in.

Push-to-talk dictation for macOS, with the rewrite done by **Apple's on-device Foundation Models** (Apple Intelligence).

**Local by design.** Everything runs on your Mac. No cloud services, no accounts, no tracking. What you say and write stays with you. [Details](#privacy-and-control)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-lightgrey)
![Apple Foundation Models](https://img.shields.io/badge/Apple%20Foundation%20Models-on--device-blueviolet)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange)
![Status: early](https://img.shields.io/badge/status-early-yellow)

[Features](#features) · [Install](#install) · [Usage](#usage) · [How it works](#how-it-works) · [Privacy](#privacy-and-control) · [Contributing](#contributing)

</div>

---

Ordinary dictation writes down everything you say: the false starts, the "um, actually, no", the three attempts at the same sentence. You end up editing more than you saved.

Plainspoken is a free, open source menu bar app for macOS that fixes that. It listens while you hold a key, then types the version of the text you would have written if you'd composed it carefully, in your own words. The cleanup is done by Apple's Foundation Models, the on-device language model behind Apple Intelligence, and the speech recognition is Apple's on-device speech framework. Plainspoken ships no model of its own and calls no cloud service: no servers, accounts or API keys. The one optional extra is [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), an open source package that runs OpenAI's Whisper locally; its model is downloaded only if you choose Whisper in Settings and agree to the prompt.

```
you say:   "let's meet Tuesday no wait Thursday afternoon and send the notes to Priya
            actually scratch that send them to the whole team"

it types:  "Let's meet Thursday afternoon and send the notes to the whole team."
```

| You say | It types |
|---|---|
| "so the thing is um what I mean is the Jira board is out of date" | The Jira board is out of date. |
| "for the launch we need first the landing page second the pricing table and then the announcement email" | A short lead-in and a numbered list |
| "write me a poem about the ocean" | Write me a poem about the ocean. (It rewrites what you said. It never answers or obeys it.) |

> **Status:** early (v0.1). It works day to day on the author's Mac, but it has been tried in only a few apps and its rewrite quality is still being checked against real speech. Expect rough edges, and please [report them](#contributing).

<!-- TODO: add a short screen recording of the listening bar and a typed result. -->

## Features

- **Push-to-talk anywhere.** Hold a key, talk, release. Text lands in whatever app and field has focus.
- **Rewrites for intent.** Keeps only the final version of a self-correction, drops "scratch that" and "let me rephrase", merges repetition, formats spoken lists, and keeps your own voice.
- **Never answers you.** Dictate a question and you get the question back. Dictate a command and you get the command written out, not carried out.
- **Local, private and in your control.** Speech recognition and the rewrite both run on your Mac. Your voice and text are never sent anywhere, and nothing is saved to disk. See [Privacy and control](#privacy-and-control).
- **Optional Whisper for accents.** Off by default. Pick Whisper in Settings > Dictation and the app explains the one-time download (about 150 to 650 MB depending on the size) before fetching it. Settings also has a plain-language guide to which engine and size suits you, and you can remove the download at any time.
- **Always gives you something.** If the rewrite is unavailable or looks wrong, it falls back to light cleanup, then to the raw transcript.
- **Careful with your clipboard.** Typing goes through Accessibility when it can. When it has to paste, your clipboard is saved and restored.
- **A bar you can see, and click.** A small pill at the bottom of the screen shows the app is alive, then turns into a live waveform while you talk. Click the pill to start dictating and click it again to finish, if you'd rather not use the keyboard. Choose a green oscilloscope or a pixelated Fire visualizer.
- **Pick your microphone.** Use the built-in mic while wearing Bluetooth headphones and they stay in high-quality listening mode.
- **Custom vocabulary.** Names and product terms live in a plain text file you edit anywhere, with aliases for words the recognizer keeps mishearing.

## Built on Apple Foundation Models

The rewrite step, the part that turns "Tuesday, no wait, Thursday" into "Thursday", is Apple's [Foundation Models framework](https://developer.apple.com/documentation/foundationmodels): the roughly 3-billion-parameter model that powers Apple Intelligence, running locally on your Mac's Neural Engine and GPU. Plainspoken wraps it with a fixed prompt, guards that reject bad output, and fallbacks.

- **Nothing to install.** The model is part of macOS 26. You turn Apple Intelligence on in System Settings and macOS downloads the model once.
- **Needed for the rewrite, not for transcription.** Speech recognition uses a separate Apple on-device speech model. If Apple Intelligence is off or unavailable, Plainspoken falls back to light cleanup (fillers, spacing, capitalization) and tells you why, so you get a plain transcript instead of a rewritten one.
- **Availability is Apple's call.** Apple Intelligence has to be supported on your Mac, region and language. If it isn't, expect the light-cleanup fallback.

## Requirements

- macOS 26 (Tahoe) or later
- Apple silicon
- **Apple Intelligence turned on** (System Settings > Apple Intelligence & Siri), because the rewrite runs on Apple's on-device Foundation Models. Without it you still get transcription, with light cleanup instead of a rewrite.
- To build from source: Swift 6.2 or later. The Xcode Command Line Tools (`xcode-select --install`) are enough; full Xcode isn't required.

English is the only language it has been tested in.

## Install

There is no prebuilt download yet. Build it from source:

```bash
git clone https://github.com/darin2036/Plainspoken.git
cd Plainspoken
scripts/build-app.sh
open build/Plainspoken.app
```

Move `build/Plainspoken.app` to `/Applications` to keep it. `scripts/build-app.sh debug` makes a debug build.

### Signing

macOS ties the Microphone, Input Monitoring and Accessibility permissions to an app's code signature. The build script signs with the first code-signing identity it finds (a free Apple Development certificate from Xcode works). To choose one:

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/build-app.sh
```

With no identity it falls back to an ad-hoc signature, and macOS forgets the permissions every time you rebuild.

### Updating and uninstalling

Plainspoken tells you in Settings and in the menu when a newer release is published on GitHub. To update, pull and rebuild with the same signing identity, so your permissions carry over:

```bash
git pull && scripts/build-app.sh
```

Settings > General > Updates shows which build you're running, such as `0.1.0 (build 12, a1b2c3d)`: the release version, the commit count and the git commit (`-dirty` if built with uncommitted changes).

**For maintainers:** the release version lives in `CFBundleShortVersionString` in `App/Info.plist`. To announce a new one, raise that number, commit, then publish a GitHub release tagged `v` plus the version (for example `v0.1.1`). The in-app update check compares against the latest published release.

To uninstall, quit the app and delete it, then optionally remove its data and permissions:

```bash
rm -rf "$HOME/Library/Application Support/Plainspoken"
defaults delete io.github.darin2036.Plainspoken
```

Also remove Plainspoken from the Microphone, Input Monitoring and Accessibility lists in System Settings > Privacy & Security.

## Usage

Plainspoken lives in the menu bar (a microphone icon, no Dock icon). The first time you open it, grant three permissions from the checklist:

| Permission | Why |
|---|---|
| Microphone | To hear you |
| Input Monitoring | To notice the hold-to-talk key |
| Accessibility | To type the result into other apps |

You don't need to relaunch after granting; the checklist updates on its own. A small pill sits at the bottom of the screen while the app runs, and it's orange until setup is complete.

Then click into any text box, **hold Right Option**, talk, and release. The bar shows your words as you say them, then "Rewriting…", then the final text, which is typed at your cursor.

### Settings

Open them from the menu bar icon.

| Setting | What it does |
|---|---|
| **Hold to talk** | Right Option (default), Right Command, Right Control, Right Shift, or Fn/Globe. Fn can collide with the system's dictation and emoji shortcuts. |
| **Microphone** | Any input. The built-in mic keeps Bluetooth headphones out of call mode, which adds latency. Plainspoken captures from the device you pick and never changes your system's default input or output. |
| **Paste when no text box is detected** | On by default. Pastes even if no text box is visible, which suits apps that hide their fields from Accessibility, and leaves the text on your clipboard in case it didn't land. Off: it only copies the text. |
| **Listening display** | Oscilloscope or Fire, with a preview button that uses a test voice. |
| **Idle indicator** | Turns the small resting pill on or off. Click the pill to start dictating; click it again to finish. |
| **Speech engine** | `SpeechTranscriber` (newer) or `DictationTranscriber` (classic). Try both on your own voice. |
| **Custom vocabulary** | Opens the vocabulary file, described next. |

### Custom vocabulary

Names and terms live in a plain text file at `~/Library/Application Support/Plainspoken/vocabulary.txt`. Open it from Settings > Dictation, or edit it anywhere. One entry per line; lines starting with `#` are ignored.

```
# my terms
Jira
Confluence
Rovo=bravo|robo
```

Plain terms are passed to the recognizer, used to fix casing and one-letter slips ("confluence" becomes Confluence, "Jera" becomes Jira), and mentioned to the rewrite. For a word the recognizer keeps mishearing, add an alias: `Rovo=bravo|robo` turns "bravo" and "robo" into "Rovo". Changes apply to your next dictation, with no restart.

## How it works

```
hold key  ->  microphone  ->  Apple on-device speech recognition   (live text in the bar)
release   ->  Apple Foundation Models rewrite  ->  type into the focused app
                  |  if the rewrite is rejected or unavailable
                  v
              light cleanup (fillers, spacing, capitalization)  ->  raw transcript
```

- **Speech recognition** uses Apple's on-device `SpeechAnalyzer`.
- **The rewrite** uses Apple's on-device Foundation Models, the small model behind Apple Intelligence. It's told to rewrite and never to answer, so a dictated question stays a question.
- **Guards** reject a rewrite that looks wrong: empty output, much shorter or longer than what you said, too many words you never spoke, an answer-style opening, or a timeout (4 seconds per call). A rejected rewrite falls back to light cleanup, then to the raw transcript.
- **Typing it in** first tries the Accessibility API, which doesn't touch your clipboard. If a text box won't take that, it pastes with Cmd+V and restores your clipboard afterwards. If it can't find a text box at all, it pastes anyway and leaves the text on your clipboard (a setting turns the paste off). If you switch apps while it's working, it types nothing and puts the text on the clipboard instead. It refuses password fields.
- **Long monologues** are split on sentence boundaries and rewritten piece by piece.

## Privacy and control

Plainspoken is designed to run entirely on your Mac, with your privacy and your control as the point rather than a side effect.

- **No cloud services.** Speech recognition and the rewrite both run on-device. There is no server to send anything to, no account to create and no API key to paste in.
- **Your voice and words are ephemeral.** Audio and transcripts exist in memory only while they are being processed, and the last result is kept in memory for the menu until your next dictation or until you quit. Plainspoken doesn't save recordings or transcripts to disk, and it doesn't write them to logs: its logs hold only timings and error types, never what you said or wrote. The only things it stores are your preferences, your vocabulary file and any model you choose to download.
  - One thing outside the app's hands: when text can't be typed directly, it's pasted or left on your clipboard, and what happens to the clipboard after that is up to macOS and any clipboard manager you use.
- **No tracking.** No telemetry, analytics or crash reporting.
- **Works offline, and enforces it.** Once the models are on your Mac, dictation needs no internet connection. Plainspoken blocks its own web requests at all times except while a download you approved is running, so even a bug or a misbehaving dependency couldn't send anything out during dictation. A blocked attempt fails and is logged by host name only.
- **Online only for two things, both visible and switchable.** Plainspoken blocks its own web requests at all other times.
  - *Speech models.* Apple's are downloaded by macOS itself, the first time you use them. Whisper is off by default. Only if you choose it in Settings and confirm the prompt (which states the size) does Plainspoken download the model from [Hugging Face](https://huggingface.co/argmaxinc/whisperkit-coreml). That includes a small tokenizer file and a check for the model's current version, all from the same site. Hugging Face can see your IP address and which files you asked for, never anything you say or write. Once the download finishes, the app is offline again.
  - *Update check.* About once a day the app asks GitHub whether a newer release exists, by requesting this project's latest release. The request carries nothing about you or your Mac, not even your version, and GitHub sees only your IP address. If there's a newer one, Settings and the menu show it and a button opens the release page; Plainspoken never downloads or installs anything by itself. You can turn the daily check off in Settings > General, and then it only happens when you press Check for Updates.
- **You stay in control.** Downloaded Whisper models can be removed in Settings at any time. The code is open source, so you can check all of this.

## Troubleshooting

- **The pill is orange, or the hotkey does nothing.** A permission is missing. Open the menu and look for the unchecked row. If a permission shows as granted in System Settings but not in the app, remove it from the list and add it again, or rebuild with a stable signing identity (see [Signing](#signing)).
- **"Rewrite fell back to light cleanup."** The on-device model was unavailable, took too long, or its output failed a guard. The menu shows the reason. Apple Intelligence must be enabled and its model downloaded.
- **Text isn't typed in some app.** Some apps, mostly Electron and web apps, won't accept Accessibility writes, so Plainspoken pastes instead. If an app doesn't expose its text boxes at all, it pastes anyway and leaves the text on your clipboard, so you can paste it yourself if it didn't land.
- **Text went to the clipboard instead of the app.** You switched apps between starting to talk and the text arriving, so it deliberately didn't type into the wrong place.
- **A name keeps coming out wrong.** Add it to the vocabulary file, with an alias if needed.

## Development

```
Sources/PlainspokenCore/   Rewriter, Prompts, Guards, LightCleanup, Vocabulary, Chunker, Transcriber
Sources/PlainspokenApp/    menu bar app, hotkey, audio capture, bar, visualizers, text insertion
Sources/Harness/           command-line tool for tuning the rewrite without the app
Harness/samples.json       test sentences: {raw, ideal, category}
App/                       Info.plist and entitlements
scripts/build-app.sh       builds and signs build/Plainspoken.app
```

The rewrite harness is where most of the quality work happens:

```bash
swift build --product harness

.build/debug/harness --pipeline --runs 3                 # full fallback chain over samples.json
.build/debug/harness --text "um let's meet Tuesday no wait Thursday"
.build/debug/harness --vocab "Jira,Rovo=bravo" --pipeline
.build/debug/harness --transcribe clip.aiff --rewrite    # audio file through speech and rewrite
.build/debug/harness --stress 3                          # long transcript, exercises chunking
```

Other flags: `--temp`, `--schema`, `--only N`, `--engine dictation`, `--instructions file.txt`. The prompt lives in `Sources/PlainspokenCore/Prompts.swift`. Keep its few-shot examples out of `samples.json`, or the scores are inflated.

The app has a few dev hooks: `--render-previews <dir>` and `--render-settings <dir>` write PNGs of the bar and the settings tabs, `--mic-test [uid]` records two seconds and reports what arrived, and `--insert-test "text" [seconds] [paste] [app=bundle.id]` types into a target app and checks that the clipboard survived.

**The bundled `samples.json` is synthetic.** Every sentence and "ideal" was written by hand, so its scores are an upper bound on real-world quality. If you add samples from your own speech, keep them in a git-ignored file such as `Harness/samples.local.json` rather than committing them. It's your voice and your words.

## Contributing

Issues and pull requests are welcome. The most useful reports are:

- an app where text insertion fails,
- a phrase the rewrite gets wrong (what you said, what you got, what you wanted),
- anything that behaves differently on your Mac or macOS version.

For code changes, run the harness before and after if you touched the prompt or guards, and add a line to [CHANGELOG.md](CHANGELOG.md) under "Unreleased" for any user-visible change.

## Roadmap

- A Verbatim mode (light cleanup only) and a per-use way to switch modes
- Tone hints per app (Mail, Slack, and so on)
- Launch at login
- A signed, notarized download

## Related projects

Push-to-talk dictation for the Mac is a busy area. If Plainspoken isn't what you need, these are worth a look: [Ghost Pepper](https://github.com/obra/ghost-pepper), [Murmur](https://github.com/daviddao/murmur) and [Megaphone](https://github.com/Kuberwastaken/megaphone).

## License

[MIT](LICENSE).

Plainspoken is an independent project and isn't affiliated with or endorsed by Apple. Apple, macOS and Apple Intelligence are trademarks of Apple Inc.
