# Language Transcriber

A native macOS app for live, bilingual transcription on calls and meetings. Capture your microphone, the audio from a video call, or both — and see what's being said in two synchronized columns: your chosen non-English language on the left, English on the right.

Built on OpenAI's [Realtime Translation API](https://developers.openai.com/api/docs/guides/realtime-translation). Two WebSocket sessions run in parallel — one targeting English, one targeting the picked language — so the EN and OTHER columns are always row-aligned across the same underlying audio.

## Features

- **Bidirectional live translation** between English and any of ~20 common languages (Portuguese, Spanish, French, German, Japanese, Mandarin, Korean, Hindi, Arabic, etc.)
- **Three audio sources**: microphone, system audio (Zoom / Google Meet / Webex / anything playing through your speakers), or both mixed together
- **Stable scrollback** — the history column is yours to read through without being yanked to the bottom every time a new line arrives; a separate live pane at the bottom shows the current utterance
- **Per-column or per-paragraph copy** to the system clipboard
- **API key stored in the macOS Keychain** (no plain-text disk storage by default)
- **Live diagnostics** — permission badges, bytes uploaded, deltas received, last-frame age — all in the status bar
- **Native Swift Package**, no Xcode project required — `./build.sh` produces an ad-hoc-signed `.app` bundle

## Requirements

- macOS 13 (Ventura) or later
- Xcode command-line tools (`swift --version` should work)
- An OpenAI API key with access to `gpt-realtime-translate`

## Build

```bash
./build.sh
# → build/LanguageTranscriber.app
```

The script builds the Swift package, wraps the executable into a `.app` bundle with the right `Info.plist` + entitlements + icon, and applies an ad-hoc code signature.

## Configure your API key

Open the app, hit **⌘ ,** to open Settings, paste your key, and click *Save to Keychain*. That's it — the key lives in your macOS Keychain under service `com.harnit.LanguageTranscriber`.

If you prefer a file, drop a `config.json` next to the app:

```bash
cp config.example.json build/config.json
# edit build/config.json and paste your OpenAI key
```

Loading order (first hit wins):

1. macOS Keychain
2. `./config.json` (current working directory)
3. `config.json` alongside the `.app` bundle
4. `~/.config/language-transcriber/config.json`
5. `~/.language-transcriber.json`
6. `OPENAI_API_KEY` environment variable

### Config fields

| Field | Default | Notes |
|---|---|---|
| `apiKey` | — | Your OpenAI API key. Strongly prefer the Settings → Keychain path. |
| `model` | `gpt-realtime-translate` | Realtime translation model. |
| `otherLanguage` | `pt` | ISO 639-1 code for the non-English pane. |
| `segmentSilenceMs` | `1500` | Ms of no deltas before the live buffer is pushed to history. |

## Run

```bash
open build/LanguageTranscriber.app
# or drag it into /Applications and launch from Spotlight
```

On first launch macOS will prompt for **Microphone** permission (for Mic and Both modes) and **Screen Recording** permission (for System Audio and Both modes — required by ScreenCaptureKit even though we discard the video). After you grant Screen Recording, fully quit and relaunch the app so the new permission takes effect.

### Tips

- **Use headphones** in Both mode. Without them, your speakers leak the call audio back into your microphone, and the model will transcribe the same utterance twice. A built-in Jaccard-similarity dedup catches most of these, but headphones are the cleanest fix.
- **Pin the language** via `otherLanguage` in `config.json` (or just pick from the toolbar dropdown). You can switch any time while the app is idle.
- **Copy** — column headers have a *Copy* button; right-click any row for per-row copy options.
- **Press Space** to start/stop while the window is focused.

## Architecture

A short tour of `Sources/LanguageTranscriber/`:

| File | Role |
|---|---|
| `TranscriberApp.swift` | `@main` SwiftUI entry; declares the main window + Settings scene |
| `ContentView.swift` | Two-column transcript UI, live pane, status bar, copy actions |
| `TranscriberViewModel.swift` | State + orchestration: connects clients, runs flush timer, dedup |
| `RealtimeClient.swift` | WebSocket client for `wss://api.openai.com/v1/realtime/translations` |
| `MicrophoneCapture.swift` | `AVAudioEngine` mic input |
| `SystemAudioCapture.swift` | `ScreenCaptureKit` system audio (macOS 13+) |
| `AudioConverter.swift` | Resamples any input to 24 kHz mono Int16 PCM |
| `AudioMixer.swift` | Sums mic + system PCM streams in Both mode |
| `KeychainStore.swift` | Stores/loads the API key in the macOS Keychain |
| `Config.swift` | Reads `config.json` from the well-known locations |
| `SettingsView.swift` | In-app Settings window (⌘ ,) |
| `Languages.swift` | The dropdown's language list and `displayName` lookup |
| `Permissions.swift` | Live mic + screen-recording permission state |

### Top-level files

```
.
├── Package.swift                # SwiftPM manifest
├── Sources/LanguageTranscriber/ # Swift sources (see above)
├── Resources/
│   ├── Info.plist               # bundle metadata + permission strings
│   ├── LanguageTranscriber.entitlements
│   ├── AppIcon.icns             # generated by make-icon.sh
│   └── make-icon.sh             # regenerates AppIcon.icns from scratch
├── config.example.json
├── build.sh                     # builds .app bundle
├── package.sh                   # bundles the .app into a shareable zip / dmg
└── README.md
```

## Distributing it

For yourself:

```bash
cp -R build/LanguageTranscriber.app /Applications/
```

For peers, run:

```bash
./package.sh --dmg
```

That produces `dist/LanguageTranscriber-<version>-<date>.zip` and `.dmg`. Since the build is only **ad-hoc signed**, recipients will see Gatekeeper warnings. They can either right-click → Open → "Open Anyway", or strip the quarantine bit with `xattr -cr /Applications/LanguageTranscriber.app`. For a smoother distribution path you'd sign + notarize with a paid Apple Developer ID — PRs welcome on that front (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Contributing

PRs and issues welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

Some ideas to get started:
- Real acoustic speaker diarization (split "remote callers" into individual speakers)
- Acoustic echo cancellation that doesn't break system-audio capture
- Apple Developer ID signing + notarization in the build pipeline
- A menu-bar mode for always-on background transcription
- Export options (Markdown, VTT, plain text) from the toolbar

## License

MIT. See [LICENSE](LICENSE).

Your OpenAI key is yours and stays on your machine. The app talks directly to OpenAI's servers; no transcripts pass through any third-party infrastructure.
