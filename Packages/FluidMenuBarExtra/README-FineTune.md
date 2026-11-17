# FluidMenuBarExtra (vendored)

Source of [FluidMenuBarExtra](https://github.com/wadetregaskis/FluidMenuBarExtra) 1.5.1
(revision `3ce81bd0e5ab0ae5b027076482f4bd86be30162c`), by Lukas Romsicki and Wade Tregaskis,
MIT License (see `LICENSE`). Kept as a local package so FineTune can change its behaviour.

Changes made for FineTune:
- `FluidMenuBarExtraBehavior.swift` (new): `dismissesOnFocusLossProvider`, `onStatusItemPress`, `dismiss()`.
- `FluidMenuBarExtraStatusItem.swift`: honours those switches (window kept open on focus loss
  when asked, press callback, explicit dismiss).
- `Package.swift`: tools 5.9 and macOS 14 (FineTune's own minimum), for `MainActor.assumeIsolated`.
- `FluidMenuBarExtra.body`: the placeholder scene is a never-inserted `MenuBarExtra` instead of `Settings {}`, so the host app keeps a single "Settings…" menu item.
