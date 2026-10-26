<div align="center">

# <picture><source media="(prefers-color-scheme: dark)" srcset=".github/assets/honeycomb-dark.svg"><img src=".github/assets/honeycomb.svg" alt="" height="40" align="texttop"></picture> Honeycomb

### Free, private AI meeting notes for macOS.

Honeycomb listens to your calls without joining them and writes the notes for you, all on your Mac.

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20Silicon-000000)](#install)
[![Local](https://img.shields.io/badge/runs-100%25%20on%20your%20Mac-2ea44f)](#how-it-works)

**[Features ↓](#features)** · **[Install ↓](#install)** · **[How it works ↓](#how-it-works)**

</div>

## Features

- Notices calls in Zoom, Meet, Teams, Webex, Slack, and FaceTime, and asks before it records.
- Records you and the other side as separate tracks. No bot joins.
- Writes the notes when the call ends, so typing is optional.
- Shows the transcript line behind every note.
- Answers questions about one meeting or all of them, even mid-call.
- Saves each meeting as Markdown in a folder you choose.
- Writes notes with its built-in AI model.

## Install

Requires an Apple Silicon Mac with 16 GB of memory or more, on macOS 26 or newer.

```bash
curl -fsSL https://raw.githubusercontent.com/kurtjallo/Honeycomb/main/install.sh | sh
```

Or download the DMG from [Releases](https://github.com/kurtjallo/Honeycomb/releases), then click **Open Anyway** in System Settings → Privacy & Security on first launch. The first launch downloads about 3.5 GB of models.

## How it works

1. A call app starts using the mic, and Honeycomb asks whether to take notes.
2. It records your mic and the call audio as two tracks.
3. NVIDIA Parakeet transcribes both on your Mac as you talk.
4. When the call ends, Cohere Transcribe can redo the transcript for higher accuracy. It is an optional download.
5. A local AI model writes the notes.

Audio, transcripts, and notes never leave your Mac.

## Development

Needs Xcode 26 installed for its build tools.

```bash
git clone https://github.com/kurtjallo/Honeycomb.git
cd Honeycomb
./scripts/build && open build/Honeycomb.app
```

## License

[MIT](LICENSE). Speech by [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) through [FluidAudio](https://github.com/FluidInference/FluidAudio), and by [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026). Local AI by [MLX](https://github.com/ml-explore/mlx-swift-lm) and [Qwen](https://huggingface.co/Qwen/Qwen3.5-4B).
