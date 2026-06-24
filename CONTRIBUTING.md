# Contributing

Thanks for considering a contribution. The project is small and the bar is "is it useful, does it build cleanly, does the existing UI still work?"

## Dev loop

```bash
# 1. Edit Swift files under Sources/LanguageTranscriber/

# 2. Build (produces build/LanguageTranscriber.app)
./build.sh

# 3. Fully quit any previous instance and relaunch
pkill -f LanguageTranscriber 2>/dev/null || true
open build/LanguageTranscriber.app
```

Stop the running app fully before relaunching — macOS keeps the old binary in memory until you Cmd+Q (the red dot just closes the window). After each `./build.sh` the in-memory copy is stale.

## Code style

- Swift 5.9+, SwiftUI on macOS 13+
- Match the existing file structure under `Sources/LanguageTranscriber/`
- Keep `TranscriberViewModel.swift` as the single orchestrator; capture/playback/transport pieces stay in their own files
- Don't add comments that just restate the code — only explain *why* when the why isn't obvious
- No mocks for the OpenAI API — there's no test harness yet; integration is by running the app

## Things that touch macOS permissions

If you change anything in `MicrophoneCapture.swift` or `SystemAudioCapture.swift`, remember that:

- Microphone permission is per code-signed identity AND per bundle path; ad-hoc signatures change every build, but the path + bundle ID combination is usually enough for macOS to remember the grant across rebuilds
- Screen Recording permission is more finicky. If your build's permissions get "stuck", reset with: `tccutil reset ScreenCapture com.harnit.LanguageTranscriber` and relaunch
- The OS only re-checks Screen Recording permission when a *new* process starts. The running process keeps whatever it had at launch

## Things that touch the OpenAI session

If you change `RealtimeClient.swift`:

- The translation endpoint is `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`
- The session is configured via `session.update` with `session.audio.output.language` — that's the only required field
- The endpoint does **not** emit source-language `input_transcript` deltas; only `output_transcript.delta` (target language) and `output_audio.delta` (which we ignore)
- The `Events:` row in the footer dumps every event type the server actually sends with counts — handy for debugging new API revisions

## Submitting

- Open an issue first for anything non-trivial (new audio backend, new transport, model swap, packaging change) — saves round-trips on direction
- For small fixes, just open the PR
- Tests would be welcome — none exist yet, so there's no test framework to break
- If you add a dependency, justify it in the PR description (footprint, license, maintenance status)

## Reporting bugs

Include in the issue:
- macOS version (and chip family — arm64 vs x86_64)
- Build status (did `./build.sh` succeed?)
- Permission state shown in the footer chips
- Whether the `Events:` row in the footer is incrementing during the bug
- Logs from `Console.app` filtered to `LanguageTranscriber`

## Cutting a release

Releases are automated. Push a version tag and GitHub Actions builds + publishes it:

```bash
git tag v1.1.0
git push origin v1.1.0
```

This runs [`.github/workflows/release.yml`](.github/workflows/release.yml): build → `package.sh --dmg` → GitHub Release with the `.zip` and `.dmg` attached. Bump `CFBundleShortVersionString` in `Resources/Info.plist` first if you want the asset filenames to reflect the new version. See the [Releases section of the README](README.md#releases) for the full flow, including how to re-cut a tag after a fix.

## License

By contributing you agree that your contribution is licensed under the same [MIT License](LICENSE) as the rest of the project.
