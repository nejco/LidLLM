# LidLLM

A menu bar app that keeps your Mac awake with the lid closed (so Claude agents keep running), and protects it:

- **Too hot?** If the lid is closed and the CPU (default 105°C) or the battery (default 45°C) stays over its limit for 60s, or macOS reports a *critical* thermal state, it sends a push to your phone, turns keep-awake off, and puts the Mac to sleep right away. With the lid open it only notifies you.
- **Getting warm?** You get a warning push at the limit minus 10°C (CPU) or minus 5°C (battery), at most once every 15 minutes.
- **Low battery:** on battery power it sleeps at 10% (you can change this).
- Quitting the app restores normal sleep.

## Setup
1. `./build.sh --install` builds the app and copies it to /Applications. Then open it.
2. Click the ☕/moon icon and choose **Keep awake with lid closed**. The first time, it asks for your password once. This adds `/etc/sudoers.d/lidllm`, which lets only your user run `pmset -a disablesleep 0|1` and `pmset sleepnow` without a password. To undo it: `sudo rm /etc/sudoers.d/lidllm`.
3. Phone alerts: install the free **ntfy** app (iOS/Android) and subscribe to a topic name that's hard to guess. In LidLLM, open **Set up phone notifications…**, enter the same topic, then tap **Send test notification**.

## Caveat
If LidLLM is force-killed while keep-awake is on, the Mac stays in no-sleep mode. Relaunch the app (it fixes this on start), or run `sudo pmset -a disablesleep 0`.
