# Honeycomb

Honeycomb is a free, open source macOS app that takes meeting notes. It records calls without a bot, transcribes them on the Mac, and writes the notes with a local AI model. These rules apply to any coding agent working in this repo.

## Commands

```sh
xcodebuild -scheme Honeycomb -destination 'platform=macOS' build
swift test --package-path Packages/HoneycombKit
npm --prefix editor install && npm --prefix editor test
make bench    # speed and memory budgets, on Apple Silicon only
```

## Layout

- `App/` wires the modules together: menu bar, windows, pop-ups.
- `Packages/HoneycombKit/` holds one target per module: Capture, Detection, Speech, ModelHost, Providers, Pipeline, Notes, Search, Store, and the rest.
- `editor/` is the TipTap notes editor that runs in a WebView.
- `tools/` holds the tone helper, the model catalog script, and the benchmarks.
- `spikes/` holds throwaway experiments. The app never imports them.

## Rules

- Audio, transcripts, and notes never leave the Mac. The network is only for model downloads, update checks, and AI providers the user connected.
- Never start a recording without the user's click.
- Only `ModelHost` loads local models. During a recording, only the speech model and Qwen3.5-4B may be loaded.
- Audio callbacks run in real time. They only copy samples into a ring buffer: no memory allocation, locks, logging, or `async` code.
- Logs never contain transcript text, notes, meeting titles, emails, or keys.
- Every dependency needs a permissive license, such as MIT, Apache 2.0, or BSD. No GPL.
- Never commit model files, recordings, keys, signing certificates, `.plan/`, or `CLAUDE.local.md`.
- Swift 6 strict concurrency is on everywhere.
- Prove a change by running it. Run the narrowest real check and report its output.
- Write docs, comments, and PR text in plain English. Comment only to explain why.
