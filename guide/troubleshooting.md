# Troubleshooting

## No sound / audio stops working

FineTune requires the **Screen & System Audio Recording** permission to capture and route app audio.

1. Open **System Settings** → **Privacy & Security** → **Screen & System Audio Recording**
2. Find FineTune in the list and enable it
3. **Restart FineTune** — the permission doesn't take effect until relaunch

If you previously denied the permission prompt, you'll need to enable it manually from System Settings.

## The start of a sound is cut, or an app stays silent

FineTune takes an app over once it starts playing, which takes a moment. Until then the app would play directly at the device's volume, without FineTune's. **Settings → Audio → Protect App Starts** (on by default) keeps it silent for that moment instead: the first few tens of milliseconds of a sound that starts after a pause of more than 30 seconds are not heard. Switching **Mix Apps per Device** also goes silent for a moment instead of playing too loud. The protection plays nothing and keeps no output device busy, and it restarts by itself after the Mac wakes from sleep.

An app FineTune could not take over plays again after 2 seconds. If an app still stays silent or loses the start of its sounds, turn **Protect App Starts** off and report the app.

## App not appearing

FineTune only shows apps that are **actively playing audio**. If an app isn't visible:

- Make sure the app is actually producing sound (start playback)
- Check if the app is hidden. Open **edit mode** (pencil icon) and look for the eye icon next to the app name. A crossed-out eye means the app is being ignored.
- Some apps use helper processes for audio. Try restarting the app.

## App causing audio issues

Some apps don't work well with CoreAudio process taps — particularly audio processors, DAWs, VoIP tools, and apps that do their own low-level audio routing. Symptoms include distorted audio, echo, or audio cutting out.

**Fix:** Open **edit mode** (pencil icon) and click the eye icon to ignore the problematic app. This tears down the process tap entirely for that app, so it goes back to normal macOS audio routing.

Common apps that may need to be ignored:
- Audio Hijack, Loopback, and other Rogue Amoeba apps
- Some VoIP/conferencing tools with custom audio engines
- FaceTime, WhatsApp, and other calling apps (tapping can break echo cancellation, causing volume ducking)

## Volume slider not working

There are two cases.

**Per-app slider.** Some apps use helper processes to play audio rather than the main app process, so the slider you see might be controlling the wrong process. Try restarting the app. If the issue persists, check edit mode to see if the app appears as a different process name.

**Per-device slider.** When you open a device, FineTune picks a volume backend automatically:

- **Hardware**: the device reports a native volume control (most USB DACs, AirPods, built-in speakers).
- **DDC**: an external display that responds to the monitor-control protocol.
- **Software**: FineTune attenuates inside its own audio graph.

Auto-detection gets it right for most devices, but some USB DACs and HDMI/DisplayPort outputs advertise a hardware slider that doesn't actually move the output level. If the device slider doesn't change the volume, open the device inspector (the info button on the device row) and turn on **Software volume**. FineTune remembers the choice per device. The toggle is hidden when auto-detect already picked Software, because there's no alternative backend to switch to.

## Audio device not switching automatically

FineTune uses a **device priority list** to decide which output device to use. When a device connects, FineTune only switches to it if it's ranked higher than the current device. When a device disconnects, FineTune falls back to the next highest-priority device that's still connected.

By default, devices are added to the bottom of the list in the order they're first seen. Since your Mac's built-in speakers are always connected, they end up at the top (highest priority), so FineTune won't auto-switch to headphones, external speakers, or other devices when they connect.

**This is a one-time setup.** Once you set your preferred order, it's saved permanently and works across app restarts.

**How to reorder:**

1. Click the **pencil icon** in the menu bar popup to enter edit mode
2. **Drag** devices to reorder, or **click the priority number** and type a new position
3. Click the **checkmark** to exit edit mode — your order is saved

The device at position 1 has the highest priority. FineTune uses this order when selecting newly connected devices and choosing a fallback. A later output change in macOS is respected, even if it selects a lower-priority device.

If you select an output from macOS Sound settings or Control Center, FineTune follows that selection immediately. It does not distinguish manual choices from macOS automatic Bluetooth switches by timing. Apps explicitly routed to a specific device keep their own routing.

Input and output devices have **separate priority lists** — switch between them using the tabs in edit mode.

> **Note:** For AirPods, taking them out of your ears and putting them back in (without the case) is handled by macOS Automatic Ear Detection. FineTune doesn't interfere with that.

## Input devices not showing

FineTune's input device monitoring requires separate microphone permission.

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Find FineTune and enable it
3. Restart FineTune

## Media keys don't control FineTune

Media keys (F10 / F11 / F12) are opt-in and require the **Accessibility** permission so FineTune can observe the keystrokes.

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Enable FineTune in the list. If it's already on, toggle it off and back on to clear a rare permission-bootstrap race.
3. Open FineTune Settings → **Shortcuts**, turn on **Capture Volume Keys**, then pick FineTune's HUD style (Tahoe or Classic), or turn it off with **Use FineTune HUD**

If the keys still don't work right after launch, a WindowServer handoff can briefly swallow the first keypress. Try once more; subsequent presses are reliable.

## Volume HUD not appearing

- Check Settings → **Shortcuts**. **Use FineTune HUD** shows FineTune's HUD; turned off, no indicator shows while FineTune captures the volume keys, for apps that show their own (a notch app). macOS's own indicator can't show a level FineTune sets: turn **Capture Volume Keys** off to get it back, with macOS's volume steps.
- With macOS Zoom magnifying the screen, turn on **Absolute Position** to show the HUD in the part of the screen you see, in the same corner. Off (the default), the HUD keeps its place on the whole screen, which Zoom may not show.
- Switch HUD styles if one isn't rendering. Tahoe uses macOS 26's system HUD look; Classic matches the older translucent rounded-rect style.

## EQ not applying / sounds the same

- The EQ is enabled by default. Check that the **toggle switch** in the EQ panel header is on.
- The default preset is **Flat** (all bands at 0 dB), which makes no audible changes. Select a different preset or adjust the bands manually.
- EQ is **per-app**, not per-device. Make sure you're adjusting the EQ for the correct app.
- If using AutoEQ headphone correction, that's separate from the 10-band EQ. Verify a profile is assigned to the correct device via the wand icon

## Audio quality sounds degraded

- Check if volume boost is set above 1x — high boost levels can cause clipping on loud passages
- If using EQ, large boosts across multiple bands can push levels too high. Try pulling bands down instead of boosting others up.
- AutoEQ profiles include a preamp gain reduction to prevent clipping; manual EQ does not, so be mindful of total gain
- Try resetting the app to defaults: `open "finetune://reset"` in Terminal
