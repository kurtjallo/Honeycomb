# Spike results

## S1: system audio, mic, and call detection

| # | Check | Pass if | Result |
|---|---|---|---|
| 1 | Permission prompts | One mic prompt, one system-audio prompt | |
| 2 | Denial caught | Tone test reports it within 5 s | |
| 3 | Clean tracks | `system.caf` has only their voice (Zoom, Meet) | |
| 4 | Timing | Claps within 50 ms, drift under 20 ms over 30 min | |
| 5 | Switching outputs | No gap over 3 s (speakers → AirPods → speakers) | |
| 6 | Cost | CPU ≤ 5%, memory ≤ 150 MB | |
| 7 | Detection | Start and end logged for each app | |
| 8 | No false alarms | Wispr Flow, OpenSuperWhisper, ChatGPT voice ignored | |
| 9 | Permissions survive an update | No new prompts with the self-signed certificate | |
| 10 | Facts | Purple dot? Keychain prompt after update? | |

**Bundle IDs seen:**

| App | Bundle ID | Pop-up rule decision |
|---|---|---|
| Zoom | | |
| Meet in Chrome | | |
| Meet in Arc | | |
| Slack huddle | | |
| FaceTime | | |
| Teams | unverified | |
| Webex | unverified | |
