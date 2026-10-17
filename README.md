<div align="center">

# <picture><source media="(prefers-color-scheme: dark)" srcset=".github/assets/honeycomb-dark.svg"><img src=".github/assets/honeycomb.svg" alt="" height="40" align="texttop"></picture> Honeycomb

### AI meeting notes that never leave your Mac.

A free, open source meeting notepad for macOS. Honeycomb notices when a call starts, records it without a bot joining, transcribes it on your Mac, and writes the notes for you with a local AI model. No account, no server, and no subscription.

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20Silicon-000000)](#install)
[![Local](https://img.shields.io/badge/runs-100%25%20on%20your%20Mac-2ea44f)](#how-it-works)

**[Features ↓](#features)** · **[Install ↓](#install)** · **[How it works ↓](#how-it-works)**

</div>

## Features

- Notices calls in Zoom, Google Meet, Microsoft Teams, Webex, Slack huddles, and FaceTime, and asks before it records.
- Records your mic and the call audio. No bot joins the meeting.
- Shows a live transcript, labeled "Me" and "Them", made on your Mac.
- Writes the notes when the call ends. Typing is optional. Jot a few bullets if you want to steer it.
- Shows the transcript quote behind any line of the notes.
- Answers questions during or after a call, and runs saved prompts like "/Write follow-up email".
- Finds anything in past meetings with Cmd+K. Every meeting is also saved as a Markdown file in a folder you choose.
- Uses its built-in AI model, or yours: Ollama, LM Studio, any OpenAI-compatible server, or Anthropic.

## Install

Requires a Mac with Apple Silicon and macOS 26 or newer.

```bash
curl -fsSL https://raw.githubusercontent.com/kurtjallo/Honeycomb/main/install.sh | sh
```

Or download the DMG from [Releases](https://github.com/kurtjallo/Honeycomb/releases). macOS blocks the first open of apps from outside the App Store, so open **System Settings → Privacy & Security** and click **Open Anyway** once.

On first launch, Honeycomb downloads its speech, search, and AI models, about 3.2 GB in total.

## How it works

1. Honeycomb notices a call app using the microphone and asks whether to take notes.
2. It records two tracks: your mic as "Me" and the call audio as "Them".
3. NVIDIA Parakeet turns speech into text on your Mac as the call goes.
4. When the call ends, a local AI model reads the transcript and any notes you typed, then writes the notes in the template you picked.
5. Notes, transcripts, and audio stay in one database on your Mac.

Audio never leaves your Mac. Text leaves only if you connect a cloud AI model, and Honeycomb asks first.

## Development

Requires Xcode 26.

```bash
git clone https://github.com/kurtjallo/Honeycomb.git
cd Honeycomb
open Honeycomb.xcodeproj
```

## License

[MIT](LICENSE). Speech by [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) through [FluidAudio](https://github.com/FluidInference/FluidAudio). Local AI by [MLX](https://github.com/ml-explore/mlx-swift-lm) and [Qwen](https://huggingface.co/Qwen/Qwen3.5-4B).
