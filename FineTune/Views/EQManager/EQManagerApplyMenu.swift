// FineTune/Views/EQManager/EQManagerApplyMenu.swift
import SwiftUI

/// The Apply to DAC dropdown of the EQ Manager: the output devices that support AutoEQ, as the
/// menu bar panel lists them, each with its AutoEQ wand (the panel's, without "Open EQ
/// Manager..."). The devices hidden from the panel are left out, and listed dimmed while ⌥ is
/// held. A check after a device's name marks the devices that use the preset shown. Clicking a
/// device makes it use that preset, with its correction on.
@MainActor
struct EQManagerApplyButton: View {
    let audioEngine: AudioEngine
    /// The preset shown, as saved: what a device gets.
    let preset: AutoEQProfile
    /// Unsaved changes are shown: a device would get the saved preset, not what is shown.
    let hasChanges: Bool

    @State private var isOpen = false

    private var appearance: AppearancePreference { audioEngine.settingsManager.appSettings.appearance }

    var body: some View {
        // Read here, so the dropdown follows the devices, their AutoEQ and ⌥ while it is open
        let list = entries()

        Button {
            if !isOpen { OptionKeyMonitor.shared.start() }
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Label("Apply to DAC", systemImage: "hifispeaker")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .fixedSize()
        .help("Make an output device use this preset")
        .background(
            PopoverHost(
                isPresented: $isOpen,
                preferredColorScheme: appearance.swiftUIColorScheme,
                nsAppearance: appearance.nsAppearance
            ) {
                EQManagerApplyList(
                    entries: list.shown,
                    hiddenCount: list.hiddenCount,
                    presetName: preset.name,
                    hasChanges: hasChanges,
                    onApply: { deviceUID in
                        audioEngine.setAutoEQProfile(for: deviceUID, profileID: preset.id)
                        isOpen = false
                    }
                )
                // The wands open dropdowns of their own, in the same appearance
                .environment(\.appearancePreference, appearance)
            }
        )
    }

    /// The devices listed, in the panel's order, and how many hidden ones are left out (none
    /// while the dropdown is closed).
    private func entries() -> (shown: [EQManagerApplyEntry], hiddenCount: Int) {
        guard isOpen else { return ([], 0) }
        let showsHidden = OptionKeyMonitor.shared.isOptionDown
        let defaultDeviceID = audioEngine.deviceVolumeMonitor.defaultDeviceID
        var shown: [EQManagerApplyEntry] = []
        var hiddenCount = 0
        for device in audioEngine.prioritySortedOutputDevices where device.supportsAutoEQ {
            let isHidden = audioEngine.isOutputDeviceHiddenFromPanel(device)
            if isHidden && !showsHidden {
                hiddenCount += 1
                continue
            }
            let menu = AutoEQDeviceMenu(deviceUID: device.uid, audioEngine: audioEngine)
            shown.append(EQManagerApplyEntry(
                device: device,
                menu: menu,
                icon: DeviceIconResolver.displayIcon(
                    overrideSymbol: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid),
                    automatic: device.icon,
                    deviceName: device.name
                ),
                isDefault: device.id == defaultDeviceID,
                volumePluginName: volumePluginName(for: device),
                usesPreset: menu.selection?.profileID == preset.id,
                isHidden: isHidden
            ))
        }
        return (shown, hiddenCount)
    }

    /// The plugin that sets the device's level, for the puzzle piece on its badge.
    private func volumePluginName(for device: AudioDevice) -> String? {
        #if !APP_STORE
        guard audioEngine.outputVolumeBackend(for: device.id) == .plugin else { return nil }
        return audioEngine.volumePlugins.pluginName(for: device.id)
        #else
        return nil
        #endif
    }
}

/// A device of the Apply to DAC dropdown.
struct EQManagerApplyEntry: Identifiable {
    let device: AudioDevice
    let menu: AutoEQDeviceMenu
    let icon: NSImage?
    let isDefault: Bool
    let volumePluginName: String?
    /// The device's AutoEQ preset is the one shown.
    let usesPreset: Bool
    /// Hidden from the menu bar panel, listed while ⌥ is held.
    let isHidden: Bool

    var id: String { device.uid }
}

/// Content of the Apply to DAC dropdown.
private struct EQManagerApplyList: View {
    let entries: [EQManagerApplyEntry]
    let hiddenCount: Int
    let presetName: String
    let hasChanges: Bool
    let onApply: (_ deviceUID: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Apply “\(presetName)” to")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.top, DesignTokens.Spacing.xs)

            if hasChanges {
                note("Save or discard your changes first: a DAC gets the saved preset.")
            }

            if entries.isEmpty {
                note(hiddenCount > 0
                     ? "Every DAC that supports AutoEQ is hidden. Hold ⌥ to list them."
                     : "No connected output supports AutoEQ.")
                    .padding(.vertical, DesignTokens.Spacing.xs)
            }

            ForEach(entries) { entry in
                EQManagerApplyRow(entry: entry, canApply: !hasChanges) {
                    onApply(entry.device.uid)
                }
            }
        }
        .padding(DesignTokens.Spacing.xs)
        .frame(width: 300)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DesignTokens.Spacing.sm)
    }
}

/// A device as the menu bar panel shows it, without its volume: badge, name, AutoEQ preset and
/// wand.
private struct EQManagerApplyRow: View {
    let entry: EQManagerApplyEntry
    let canApply: Bool
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            DeviceRowBadge(icon: entry.icon, isSelected: entry.isDefault, volumePluginName: entry.volumePluginName)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.device.name)
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)
                    if entry.usesPreset {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Uses this preset")
                    }
                }
                if let subtitle = entry.menu.subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            AutoEQPicker(menu: entry.menu, showsManagerButton: false)
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .hoverableRow()
        .contentShape(Rectangle())
        .onTapGesture {
            if canApply { onApply() }
        }
        .opacity(entry.isHidden ? 0.5 : 1)
        .help(canApply ? "Use this preset on \(entry.device.name)" : "Save or discard your changes first")
        .accessibilityAddTraits(.isButton)
    }
}
