# LidLLM

A menu bar app that keeps your Mac awake with the lid closed (so Claude agents keep running), and protects it:

- **Too hot?** If the lid is closed and the CPU (default 105°C) or the battery (default 45°C) stays over its limit for 60s, or macOS reports a *critical* thermal state, it posts an alert to Slack, turns keep-awake off, and puts the Mac to sleep right away. With the lid open it only notifies you.
- **Getting warm?** You get a Slack warning at the limit minus 10°C (CPU) or minus 5°C (battery), at most once every 15 minutes.
- **Low battery:** on battery power it sleeps at 10% (you can change this).
- Quitting the app restores normal sleep.

## Download
Publishing a GitHub Release builds the app in GitHub Actions and attaches `LidLLM.dmg` to that release. On GitHub, go to **Releases → Draft a new release**, create a tag such as `v1.0`, and click **Publish**. Or run `gh release create v1.0 --generate-notes`.

Open the DMG and drag LidLLM to Applications. The app is ad-hoc signed, not notarized, so macOS blocks it on first launch. Run this once to unblock it:
`xattr -dr com.apple.quarantine /Applications/LidLLM.app`

## Setup
1. `./build.sh --install` builds the app and copies it to /Applications. Then open it.
2. Click the ☕/moon icon and choose **Keep awake with lid closed**. The first time, it asks for your password once. This adds `/etc/sudoers.d/lidllm`, which lets only your user run `pmset -a disablesleep 0|1` and `pmset sleepnow` without a password. To undo it: `sudo rm /etc/sudoers.d/lidllm`.
3. Slack alerts:
   - Go to [api.slack.com/apps](https://api.slack.com/apps) and choose **Create New App → From a manifest**. Pick your workspace and paste [slack-app-manifest.yml](slack-app-manifest.yml).
   - Click **Install to Workspace** and choose the channel for alerts. Then copy the URL from **Features → Incoming Webhooks**. If your workspace restricts apps, an admin may need to approve it.
   - In LidLLM, open **Set up Slack alerts…** and paste the URL.
   - For pushes to your phone, also enter your Slack member ID (Profile → ⋮ → **Copy member ID**), or `here`. Warnings and emergencies mention it, and Slack sends a push for mentions. Another option is to set the channel's notifications to **All new messages**.
   - Click **Send test message**.
   - The webhook URL is stored unencrypted in LidLLM's preferences, so treat it like a password.

## Caveat
If LidLLM is force-killed while keep-awake is on, the Mac stays in no-sleep mode. Relaunch the app (it fixes this on start), or run `sudo pmset -a disablesleep 0`.
