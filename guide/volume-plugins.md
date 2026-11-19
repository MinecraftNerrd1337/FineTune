# Volume Plugins

Some DACs have a hardware volume that macOS can't set. macOS shows no volume control for them, and FineTune's device details read **Auto: Software**: FineTune lowers the signal itself while the DAC stays at its own level. The maker's app sets the real level by sending the DAC its own commands, usually over a USB HID interface the DAC exposes next to its audio.

A volume plugin teaches FineTune those commands. With a plugin on, FineTune's slider, the media keys and mute set the DAC's hardware volume, and the device reads **Auto: Plugin**.

Volume plugins are not available in the App Store version.

## Install a plugin

A plugin is a single file ending in `.finetuneplugin`, which you can send by email like any other file.

1. Open **Settings > Audio**, and next to **Volume Plugins** click **Manage…**.
2. Click **Open Folder**. This opens `~/Library/Application Support/FineTune/Plugins`.
3. Copy the plugin's file into it, then click **Reload**.

The plugin's row then says what it is doing: not in use, which devices it sets, or what went wrong.

> **Use only the plugins you trust.** A plugin is a small program that sends commands to your DAC. FineTune only lets it talk to the device you gave it, but a wrong command can still put a DAC in a bad state until you unplug it.

## Choose a DAC's plugin

Open the DAC's details in the device list. Under **Volume plugin**, choose the plugin, or **None** to let FineTune set the volume as it would without plugins. FineTune remembers the choice for each DAC, and marks the DACs a plugin drives with a puzzle piece on their icon in the device list.

The menu lists the plugins written for that DAC, or says that none is. Hold **⌥** while it is open to list the others too, dimmed and behind a warning sign: FineTune asks you to confirm before using one of them, since it sends the DAC commands meant for another device. Do it only if you know the DAC speaks the same commands, with your headphones off.

To have a plugin take the DACs it is written for without choosing it in each one's details, turn on its **New DACs** switch in **Manage…**. It is off for every plugin until you turn it on. A DAC FineTune has already seen keeps the plugin it has, or none. When several plugins with **New DACs** on are written for the same DAC, the first of them in the list takes it.

When a plugin starts, FineTune takes the DAC's own level if the plugin can read it. Otherwise it sets the level it last gave that DAC, and the first time a plugin drives a DAC, no higher than half way, and never louder than its software slider stood.

## iBasso DC

FineTune comes with a plugin for iBasso's USB DACs in [`plugins/iBasso DC.finetuneplugin`](../plugins/iBasso%20DC.finetuneplugin): DC03 Pro, DC04 Pro, DC06, DC06 Pro, Macaron, DC07 Pro, DC-Tonfa, DC-Nunchaku, DC04U, Macchiato and D18. The DC-Elite is not included, because iBasso's app sends it no volume command. Install it as above, then choose it in your DAC's details, or turn on its **New DACs** switch.

The commands it sends come from [Re-ibassoUAC](https://github.com/Nayo-weiguang/Re-ibassoUAC) by Nayo-weiguang (MIT License), which documents them from an analysis of iBasso's Android app. They have been checked on a real DC03 Pro there, and with FineTune on a DC06 Pro. On another model, try the plugin at a low volume with your headphones off first, and say how it went in an issue.

- Each percent of FineTune's slider is one step of iBasso's own volume table.
- On the DC03 Pro, DC04 Pro, DC06 Pro and Macaron, the plugin starts by asking the DAC's controller for its level, so FineTune starts from the level the DAC is at, even after it was changed on another computer or a phone. If the DAC doesn't answer within half a second, FineTune sets the level it last gave it.
- On the DC03 Pro, DC04 Pro, DC06 Pro and Macaron, the plugin also gives the level to the DAC's controller, as iBasso's app does, so the DAC's own buttons go on from the level FineTune set.
- Muting silences the DAC chips but leaves the controller at its level: pressing a volume button on the DAC unmutes it from there.
- A level changed with the DAC's buttons moves FineTune's slider.

## Write a plugin

A plugin is one text file, named `Something.finetuneplugin`, holding a JavaScript script. Its manifest, which says what the plugin is and which devices it is written for, is a JSON object in a `/* @manifest … */` comment of that script, usually at its top:

```js
/* @manifest
{
  "id": "com.example.my-dac",
  "name": "My DAC",
  "author": "Your name",
  "version": "1.0",
  "description": "Hardware volume for My DAC",
  "match": {
    "vendorID": "0x1234",
    "productIDs": ["0x5678"],
    "usagePage": "0xFF00"
  },
  "hid": {
    "outputReportLength": 16
  }
}
*/

// Required. volume is FineTune's slider, from 0 to 1
function setVolume(device, volume) {
  const step = Math.round(volume * 100);
  device.hid.sendOutputReport(0, [0x01, 0x02, step]);
}
```

The manifest ends at the first `*/`, so it can't hold one, not even in a string. The file is at most 1 MB, in UTF-8.

### The manifest

| Key | |
|---|---|
| `id` | Unique, never changes: FineTune remembers by its id which DACs use the plugin, and whether it takes new DACs |
| `name`, `author`, `version`, `description` | Shown in Settings. Only `name` is required |
| `match` | The devices the plugin is written for: one rule, or a list of rules of which any can match |
| `hid.outputReportLength` | Optional. Every output report is then sent with exactly this many bytes: shorter ones are padded with zeros, longer ones are refused. Some DACs lock up when a report has another length, so set it when all your DACs take one length. Without it, reports are sent as the script builds them |
| `hid.featureReportLength` | The same, for feature reports |
| `minimumIntervalMS` | The shortest gap between two volume changes, from 0 to 500 (default 20) |

A rule of `match` names a USB vendor, then narrows it if you want:

| Key | |
|---|---|
| `vendorID` | The USB vendor ID. Required. Alone, the rule takes every product of the vendor |
| `productIDs` | Only these products |
| `excludedProductIDs` | Every product but these |
| `productNames` | Only the products with one of these names, compared without case, spaces or punctuation |
| `usagePage`, `usage` | Only the HID interface with this top-level collection. Use it when the DAC has several HID interfaces |

A rule with any other key is refused, so that a misspelled key can't quietly widen it to the whole vendor.

For example, every product of a vendor but two, and one product of another vendor:

```json
"match": [
  { "vendorID": "0x1234", "excludedProductIDs": ["0x0001", "0x0002"] },
  { "vendorID": "0x9ABC", "productNames": ["My-DAC Pro"] }
]
```

IDs can be numbers or `"0x…"` strings. To find them, plug the DAC in and run `hidutil list` in Terminal: the line for your DAC shows its `VendorID`, `ProductID`, `UsagePage` and `Product`. A rule that takes a whole vendor also takes its other devices, such as a keyboard: narrow it unless all of the vendor's HID devices are DACs your script knows.

FineTune finds the DAC's audio device from its USB IDs and port. If it can't read them, it looks for the HID interface's product name in the audio device's name or UID.

When you choose a plugin for a DAC it isn't written for, FineTune gives it the DAC's HID interface that its rules would take, if any, and otherwise the DAC's first one, vendor-defined ones first. A DAC with no HID interface, such as an HDMI display, can't use a plugin.

### The script

```js
// Required. volume is FineTune's slider, from 0 to 1
function setVolume(device, volume) {
  const step = Math.round(volume * 100);
  device.hid.sendOutputReport(0, [0x01, 0x02, step]);
}

// Optional. Without it, muting sets the volume to 0
function setMute(device, muted) {
  device.hid.sendOutputReport(0, [0x03, muted ? 1 : 0]);
}

// Optional. Runs once, when FineTune takes the DAC over
function onAttach(device) {
  const reply = device.hid.getFeatureReport(1, 8);
  if (reply) device.reportVolume(reply[2] / 100);
}

// Optional. Gets the reports the DAC sends, such as a change made with its own buttons
function onInputReport(device, reportID, bytes) {
  if (bytes[0] === 0x05) device.reportVolume(bytes[1] / 100);
}
```

FineTune calls these functions:

- `setVolume` gets the slider's position. Map it to the DAC's own steps or decibels in the plugin. FineTune doesn't call it while the DAC is muted: on unmute it calls `setMute(device, false)`, then `setVolume` with the current level.
- When the slider moves faster than the DAC takes commands, FineTune drops the levels in between and sends the latest.
- When `onAttach` reports a level, FineTune takes it as the DAC's own and sends nothing. A DAC that answers in an input report rather than a feature report: send it the question in `onAttach`, then call `device.waitForLevel(ms)`. FineTune then waits that long for `onInputReport` to report the level, and sends nothing if it does. Otherwise it sends the level it remembers. A plugin that drives several models can find out which one it has here, from `device.productName` or `device.productID`, and throw an error for a model it doesn't know: FineTune then sends that DAC nothing.

The script can use:

| | |
|---|---|
| `device.hid.sendOutputReport(reportID, bytes)` | Sends an output report. `bytes` is an array of integers from 0 to 255, at most 1024 of them. Use report ID 0 for a DAC without report IDs. Returns `false` if the DAC refused it |
| `device.hid.sendFeatureReport(reportID, bytes)` | The same, for a feature report |
| `device.hid.getFeatureReport(reportID, length)` | Reads a feature report, or returns `null` |
| `device.reportVolume(volume)`, `device.reportMute(muted)` | Tells FineTune the DAC changed by itself. A report that arrives within 400 ms of a command FineTune sent may be the DAC echoing it: FineTune waits for that time to pass, then takes the last report, unless it sent the DAC something else in between. The volume HUD shows the change, when the user has it on; pass `{ hud: false }` as a second argument to keep it from showing, for a change the user didn't make on the DAC |
| `device.waitForLevel(ms)` | In `onAttach` only: has FineTune wait up to `ms` milliseconds, at most 1000, for the level the DAC sends back, which `onInputReport` gets and reports with `device.reportVolume`. Input reports reach the plugin meanwhile |
| `device.name`, `device.uid` | The audio device being driven |
| `device.vendorID`, `device.productID`, `device.productName` | Its HID interface, as `hidutil list` shows it |
| `log(...)`, `console.log(...)` | Writes to FineTune's log |
| `sleep(ms)` | Waits up to 200 ms, for a DAC that needs a pause between two reports |

That is all a plugin can reach: no files, no network, no other device. Each DAC gets its own copy of the script, so variables at the top of the script are kept for that DAC until it is unplugged or the plugin is reloaded.

A call to the script that runs for more than 5 seconds, such as a loop that never ends, is stopped, and FineTune sends that DAC nothing more until the plugin is reloaded.

### Test it

Watch the plugin's messages and errors in Terminal:

```
log stream --predicate 'subsystem == "com.finetuneapp.FineTune" AND category BEGINSWITH "VolumePlugin"'
```

After editing a plugin, click **Reload** in **Manage…**. An error in the script shows in the plugin's row, and in the DAC's details, with its line number in the file.

## Troubleshooting

- **The plugin isn't in a DAC's menu.** The plugin isn't written for it: check the IDs and the product names in its manifest against `hidutil list`. Hold ⌥ to list it anyway.
- **The plugin is chosen, but the volume doesn't move.** If the DAC has several HID interfaces, set `usagePage` to the one the maker's app uses (often 0xFF00 or above). The DAC's details show the plugin's error, if any.
- **A plugin takes no new DAC.** Turn on its **New DACs** switch in **Manage…**, or choose it in the DAC's details.
- **"macOS doesn't let FineTune use this device".** The DAC's HID interface also acts as a keyboard or remote, so macOS asks for permission first. Allow FineTune in **System Settings > Privacy & Security > Input Monitoring**, then click **Reload**.
- **"The device has no HID interface FineTune can reach".** The DAC can't take commands from a plugin, as with a display on HDMI. Choose **None**.
- **The volume no longer moves after a test.** Unplug the DAC and plug it back in. Some DACs stop answering after a malformed command until they are powered off.
- **The DAC misbehaves with a plugin.** Choose **None** in its details, then unplug it and plug it back in.
