# AutoEQ & Headphone Correction

**English** · [简体中文](autoeq.zh-CN.md)

FineTune can apply headphone-specific frequency response corrections using profiles from the [AutoEQ](https://github.com/jaakkopasanen/AutoEq) project. This compensates for your headphones' natural frequency curve, giving you a flatter, more accurate sound.

## How It Works

Every pair of headphones colors the sound differently. Some boost bass, others are harsh in the treble. AutoEQ measures these deviations and generates corrective EQ filters. FineTune applies these filters per-device, so each pair of headphones gets its own correction profile.

Corrections are applied on top of FineTune's 10-band EQ, so you can still tweak the sound to your taste after applying a profile.

## Browse Built-in Profiles

1. Click the **wand icon** next to any headphone device in FineTune
2. Search for your headphone model by name
3. Select a profile. It's applied immediately.

Profiles are fetched on demand from the AutoEQ database and cached locally for offline use. The database includes thousands of headphones from major brands (Sony, Sennheiser, Apple, Bose, Audio-Technica, Beyerdynamic, and more).

> **Tip:** If your exact model isn't listed, try searching for the product line — similar models often share frequency response characteristics.

## Import Custom Profiles

If you have a custom measurement or want to use a profile from another source:

1. Open the **EQ Manager**, click the preset selector, then **Import File...**
2. For a filter list, pick the **Base rate** next to the button: the sample rate the filters were designed for (44.1 kHz for AutoEQ's own profiles)
3. Select your `.txt` file
4. Use the **Correction** switch in the picker to A/B the profile without removing it

FineTune accepts [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) ParametricEQ.txt files:

```
Preamp: -6.2 dB
Filter 1: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41
Filter 2: ON LSC Fc 105 Hz Gain 7.0 dB Q 0.71
Filter 3: ON HSC Fc 8000 Hz Gain 2.1 dB Q 0.71
```

### Supported Filter Types

| Code | Type | Description |
|------|------|-------------|
| `PK` / `PEQ` | Peaking | Boost or cut a narrow frequency range |
| `LS` / `LSC` | Low shelf | Boost or cut everything below a frequency |
| `HS` / `HSC` | High shelf | Boost or cut everything above a frequency |

Up to 128 filters per profile. The `Preamp` line sets a global gain offset to prevent clipping.

### GraphicEQ (Wavelet, Equalizer APO)

A `GraphicEQ:` line (AutoEQ's GraphicEQ.txt, Wavelet, Equalizer APO's graphic EQ) gives a graphic preset: a frequency/gain curve in Hz, played by one of the FIR engines. UTF-8 and UTF-16 files are read; several `GraphicEQ` and `Preamp` lines add up, and in a file with `Channel:` sections only the first section is used.

```
Preamp: -5.5 dB
GraphicEQ: 20 -1.5; 21 -1.4; 22 -1.4; ...; 19871 -3.2
```

### Base rate

A filter list is made for one sample rate: AutoEQ, like most tools, optimises its filters as biquads at 44.1 kHz, and the same filters played at 96 kHz give a slightly different curve above about 8 kHz. The **Base rate** of a preset (EQ Manager, edit mode) tells the exact engines which curve to reproduce:

- **Exact biquad** and the **FIR** engines reproduce the curve the filters have at the base rate, at any device rate. At the base rate itself the exact biquads are the standard ones.
- **Biquad** re-tunes each filter's frequency for the device rate, as before.
- **Analog** treats the filters as analog prototypes, for lists designed that way.

### Linear-phase precision

The **Linear-phase FIR** engine adds a latency: it uses the shortest filter that follows the curve closely enough. **Precision** (EQ Manager, edit mode, shown with that engine) sets how closely: ±0.5 dB above 100 Hz by default, from ±0.05 to ±1 dB, and twice as loose at 20 Hz. A tighter precision gives a longer filter, so more latency and a little more CPU. The latency stops at 85 ms: **Latency** and **Max error** show what the filter actually reaches.

## Where to Get Profiles

- **Built-in search** — The easiest way. Thousands of headphones are available directly in FineTune.
- **[autoeq.app](https://www.autoeq.app/)** — Web-based tool with more options. Select **EqualizerAPO ParametricEq** as the equalizer app, download the file, and import it into FineTune.
- **[AutoEQ GitHub](https://github.com/jaakkopasanen/AutoEq)** — The full repository of measurements and generated profiles.
- **Custom measurements** — If you've measured your headphones yourself (e.g., with a MiniDSP EARS or similar), you can create a ParametricEQ.txt file in any text editor following the format above.

## Templates, Presets and History

The EQ Manager keeps two kinds of profiles:

- **Templates**: imported files and profiles downloaded from the AutoEQ catalog. Their bands (or curve) and preamp never change. Their name, base rate, correction engine and precision can be edited.
- **Presets**: created in the EQ Manager, empty or from a template, and edited in place.

The **Use On** menu of the EQ Manager plays the preset shown on your output devices: check a device to make its AutoEQ use the preset, uncheck it to turn its correction off (its selection is kept, as with the wand's **Correction** switch).

To hear a preset as you edit it, pick a device in the **Listen** menu (or open the EQ Manager from that device's AutoEQ menu, which listens on it and shows its preset). That device then plays the preset shown, unsaved changes included, and nothing is stored. The bar below the toolbar compares by ear: **Edited** (with your changes), **Saved** and **In Use** (what the device plays without the EQ Manager). Its **Correction** and **Preamp** switches are the ones of the device's AutoEQ menu: turning Correction off plays the preset's preamp only, at the same level, and both switches stay as you leave them once the EQ Manager is closed. **Use on** makes the device keep the preset shown. **Stop Listening**, or closing the window, gives the device its own AutoEQ back.

Turning a device's correction off keeps its preamp. With **Settings → Audio → Same Loudness with Correction Off** (on by default), it also adds to the preamp the level the curve takes away or adds, shown as **Perceived level** in the EQ Manager. A GraphicEQ curve sitting around −10 dB then sounds as loud with the correction off as on. Neither the preset nor its preamp is changed, and turning **Preamp** off turns the level match off too. The level is the change in power (RMS) of music played through the curve, with music modelled as the same level in every octave up to 500 Hz and falling 3 dB per octave above, as the long-term spectrum of most recordings does. Switching the correction on or off changes the preamp and the curve on the same sample: it may click, but it never plays louder than both settings.

Changing the bands of a template saves a new preset, which remembers its template (**Replace → With Its Template** brings its bands back). The new preset can take over from the template on the devices that used it.

Saving a preset asks for confirmation first (turn it off in **Settings → Audio → EQ Manager Presets**, or with the checkbox of the dialog), and the version it replaces is kept in the preset's **History** menu, where any earlier version can be restored. The number of versions kept is a setting (10 by default, 0 turns the history off). **Reset All Settings** keeps your presets and templates.

Presets edited in place by earlier versions of FineTune are kept: an imported file that was edited becomes a template again, and its edited version becomes a preset used by the same devices.

## Converting Presets

The **Convert** menu of the EQ Manager makes a new preset from the one shown, in another form. The preset converted is never changed, and each conversion shows how close its result is: the largest difference between the two curves from 20 Hz to 20 kHz, and its frequency.

- **To Graphic EQ**: the curve sampled from 20 Hz to 20 kHz (127 to 1024 points), for apps that read a GraphicEQ.txt (Wavelet, Equalizer APO). The usual 127 points miss a few tenths of a dB on narrow bands; 512 or 1024 points follow them within a few hundredths.
- **To Parametric EQ** (graphic presets) and **With Another Number of Bands** (parametric presets): bands fitted to the curve. Choose the number of bands, or the fewest that stay within a tolerance, the highest Q, whether shelves may be used, and the base rate of the new filters. Ten bands usually follow a smooth curve within one or two tenths of a dB; a curve with many sharp corners needs more.
- **To Another Base Rate**: the same bands, moved so that they give the same curve at another base rate, or as analog filters. Useful to export a filter list to an app that plays it at its own rate: an AutoEQ list made at 44.1 kHz and played as is at 48 kHz differs by about 0.3 dB near the top; moved to 48 kHz, by about 0.01 dB.

Fitting runs in the background and takes a few seconds; it can be cancelled.

The fitting engine follows the approach of the AutoEQ optimiser of PEQdB (all bands fitted together on frequency, gain and bandwidth), in double precision, with Levenberg-Marquardt, a search over the number and types of bands, and a final pass that minimises the largest error.

## Once per Device

By default each app plays through its own stream, so a device's correction runs once for each app playing on it. With **Settings → Audio → Mix Apps per Device**, the apps on a stereo output share one stream: each keeps its own volume, EQ and loudness, and the device's correction runs once, on their sum, followed by the limiter.

- Apps join and leave the shared stream without interrupting the others, and with no added latency.
- An app moved to another device keeps playing on the old one until its sound reaches the new one, then crossfades.
- Multichannel outputs, apps played on several devices at once, and more than eight apps on one device keep a stream of their own.

## Managing Profiles

- Each device remembers its assigned profile independently
- To temporarily bypass a profile, click the wand icon and turn **Correction** off
- To remove a profile entirely, click the wand icon and select **No correction**
- Favorite frequently-used profiles for quick access with the star icon — favorited profiles appear at the top of search results and are shown when the search field is empty
