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
2. Select your `.txt` file
3. For a filter list, FineTune then asks for the sample rate the filters were designed for (44.1 kHz for AutoEQ's own profiles). A graphic curve does not need one
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

To delete a preset or a template, right-click it in the preset selector, then **Delete...**. Its version history goes with it, and the devices that used it are left with no AutoEQ preset. It cannot be undone.

**Apply to DAC** makes an output device use the preset shown, with its correction on; a preset can be used on several devices. It lists the devices that support AutoEQ as the menu bar panel does, each with its wand, which opens the same menu as in the panel. The devices hidden from the panel are listed too, dimmed, while ⌥ is held. A check after a device's name marks the devices that already use the preset shown. With unsaved changes, save or discard them first: a device gets the saved preset. The preset selector lists the preset shown first. The cross that appears over it shows no preset, without choosing another one.

The **Scale** slider and field above the graph set its dB scale, from ±1 to ±24 dB. Hold ⌘ and scroll or drag the graph to move it up or down, or click its top, middle or bottom level to type one: 0 in the middle centers it. The graph never goes past ±24 dB.

While you edit a preset, the connected devices that use it play your changes as you make them, unsaved. **Saved** and **Edited**, in the middle of the edit bar, switch them between the preset as saved and your changes; ⌘B switches too. Each device follows its Correction switch. Nothing is stored until you save, and once you leave edit mode, or close the window, the devices play the saved preset again.

**Compare** sets another preset against the one in the top bar. A bar shows under the top bar. **Show** picks which of the two the window shows and edits: the preset of the top bar, in the accent color, or the compared preset, in orange. The shown preset's curve, bands and controls take its color, and the other preset's curve is drawn under it. Each preset has a pencil, which edits it alone and shows it; **Edit** in the top bar edits the preset of the top bar too. Either can be edited without the other, and each keeps its unsaved changes (marked **Edited**). A filled pencil marks the preset edited in the window, an outlined one a preset in edit mode that is not shown, and the edit bar names the preset it edits. While comparing, **Compare** in the top bar reads **Change**: it compares with another preset, once the compared one has no unsaved changes. What the devices that use the preset of the top bar play is chosen apart, in the middle of the bar: that preset, its edits, or the compared preset, as saved or with its edits. Starting an edit of the preset you hear goes on with its edits; ⌘B goes back to the version heard before. Compare works while you edit too: your edits stay. Choosing the compared preset in the preset selector puts it in the top bar, with its edits, and ends the comparison.

While comparing, **Level match** in the Preamp section is a gain added to the compared preset, and **Compared preamp** shows its preamp plus that gain (**Compared gain** with the preamp off, which this gain does not follow). On **Auto**, it makes the compared preset sound as loud as the one shown, worked out from what each device plays: its Correction switch, the Preamp switch, both preamps and both curves, as they are at that moment. It follows every change of these, and covers the saved version and the edits of the compared preset alike. Set it with the field or the slider to keep it fixed; **Auto** matches the levels again. The orange curve is drawn at the level it plays at, so with the levels matched both curves sit around the same line. Closing the window plays the saved preset again; the comparison is still there when it opens.

Turning a device's correction off keeps its preamp. With **Settings → Audio → Same Loudness with Correction Off** (on by default), it also adds to the preamp the level the curve takes away or adds, shown as **Perceived level** in the EQ Manager, where a thin line under the curve marks it on the graph. A GraphicEQ curve sitting around −10 dB then sounds as loud with the correction off as on. Neither the preset nor its preamp is changed, and turning **Preamp** off turns the level match off too. The level is the change in power (RMS) of music played through the curve, with music modelled as the same level in every octave up to 500 Hz and falling 3 dB per octave above, as the long-term spectrum of most recordings does. Switching the correction on or off changes the preamp and the curve on the same sample: it may click, but it never plays louder than both settings.

Changing the bands of a template saves a new preset, which remembers its template (**Replace → With Its Template** brings its bands back). The new preset can take over from the template on the devices that used it.

Saving a preset asks for confirmation first (turn it off in **Settings → Audio → EQ Manager Presets**, or with the checkbox of the dialog), and the version it replaces is kept in the preset's **History** menu, in the edit bar, where any earlier version can be restored into your edits. The number of versions kept is a setting (10 by default, 0 turns the history off). **Reset All Settings** keeps your presets and templates.

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
