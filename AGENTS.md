# Honeycomb

Honeycomb is a free, open source macOS app that listens to calls without joining them and writes the notes on the Mac. These rules apply to any coding agent working in this repo.

## Commands

```sh
./scripts/build             # builds build/Honeycomb.app
swift test                  # module tests
npm --prefix editor install && npm --prefix editor test
./scripts/bench             # speed and memory budgets, on Apple Silicon only
```

There is no Xcode project. `scripts/build` runs `xcodebuild` on the Swift package, because MLX's Metal shaders don't build with `swift build`. It then assembles and signs the `.app`.

## Layout

- `Sources/Honeycomb/` is the app target, and holds only UI: menu bar, windows, pop-ups, and the editor host.
- `Sources/HoneycombCore/` holds all logic, in folders by area: Session, Audio, Detection, Transcription, Models, AI, Notes, Store, Pipeline, Export, and Support. It imports no SwiftUI or AppKit views.
- `Tests/HoneycombCoreTests/` tests the pure logic, such as capture health, detection rules, and transcript merging, with no audio hardware.
- `editor/` is the TipTap notes editor that runs in a WebView.
- `scripts/` builds, signs, benchmarks, and releases.
- `spikes/` holds throwaway experiments. The app never imports them.

## Rules

- Audio, transcripts, and notes never leave the Mac. The network is only for model downloads and update checks.
- Never start a recording without the user's click.
- Only `ModelHost` loads local models. During a recording, only the speech model and Qwen3.5-4B may be loaded.
- Put every swappable part behind a protocol with a test fake, such as `TrackRecorder`, `TranscriptionEngine`, or `ChatProvider`.
- Write anything with timing or state as a pure state machine that returns commands, with its timings in a policy struct.
- Audio callbacks run in real time. They only copy samples into a ring buffer: no memory allocation, locks, logging, or `async` code.
- Logs never contain transcript text, notes, meeting titles, emails, or keys.
- Every dependency needs a permissive license, such as MIT, Apache 2.0, or BSD. No GPL.
- Never commit model files, recordings, keys, signing certificates, `.plan/`, or `CLAUDE.local.md`.
- Swift 6 strict concurrency is on everywhere.
- Prove a change by running it. Run the narrowest real check and report its output.
- Write docs, comments, and PR text in plain English. Comment only to explain why.
