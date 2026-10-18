# Spike S1: system audio, mic, and call detection

Throwaway code. It answers one question: can Honeycomb record both sides of a call cleanly, and notice the call, on a real Mac? The app never imports it.

## Build and run

```bash
./build.sh                 # builds build/HoneycombS1.app, ad-hoc signed
open build/HoneycombS1.app
```

Recordings and logs go to `~/Library/Application Support/HoneycombS1/`. Each recording gets its own folder with `mic.caf`, `system.caf`, `timeline.json`, and `events.log`.

## The test session (about 40 minutes)

Write each result in `spikes/RESULTS.md`.

1. **Permissions.** Run `tccutil reset All dev.honeycomb.spike.s1`, open the app, and click **Start recording**. Expect one microphone prompt and one system-audio prompt.
2. **Denial is caught.** Turn system-audio access off in System Settings → Privacy & Security, then click **Tone test**. Within 5 seconds it should say it heard nothing. Turn access back on, and the tone test should hear the tone.
3. **Clean tracks.** With headphones, start a Zoom call and a Meet call (in Chrome) with your second device. Record while the second device reads one script and you read another. Open the folder and listen. `system.caf` should contain only their voice, and `mic.caf` only yours.
4. **Timing.** In a 30-minute recording, clap near the start and near the end, close to both the mic and the second device. Then run `swift run Analyze "<recording folder>"`. Pass means under 50 ms apart in each half, and less than 20 ms of drift.
5. **Switching outputs.** During a call, switch from speakers to AirPods and back. The event list should show "Tap rebuilt", and no "gap" over 3 seconds. Run it twice, once with **Tap only (Quill)** off and once with it on. Note which setup has the shorter gap.
6. **Cost.** While recording, the top-right corner should show CPU at 5% or less and memory at 150 MB or less.
7. **Detection.** Start and end a call in Zoom, Meet in Chrome, Meet in Arc, a Slack huddle, and FaceTime. For each one, write down the bundle ID from the "mic start" line and the "pop-up rule" decision. For FaceTime, note whether FaceTime or a system helper appears.
8. **No false alarms.** Dictate for 30 seconds with Wispr Flow, then with OpenSuperWhisper. Both should show "IGNORE". Then click **Allow Accessibility** and use ChatGPT voice in a browser. It should show "IGNORE ... not a meeting site", while Meet shows "SHOW meeting".
9. **Permissions survive an update.** Run `./make-cert.sh` once, which asks for your password. Then:
   ```bash
   SIGN_ID="Honeycomb Spike Signing" VERSION=1 ./build.sh   # open it, grant mic + system audio + Accessibility
   SIGN_ID="Honeycomb Spike Signing" VERSION=2 ./build.sh   # quit, rebuild, reopen
   ```
   Version 2 should record and read browser titles with no new prompts. Then repeat with plain `./build.sh` (ad-hoc), which should ask again.
10. **Facts to note:** whether the purple recording dot appears in the menu bar, and whether the Keychain prompts after an update.

Teams and Webex have no test accounts. Mark them "unverified".
