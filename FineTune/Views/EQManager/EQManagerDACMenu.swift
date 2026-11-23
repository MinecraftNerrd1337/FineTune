// FineTune/Views/EQManager/EQManagerDACMenu.swift
import SwiftUI

/// The DACs dropdown of the EQ Manager, there with or without a preset shown: the output devices
/// that support AutoEQ, as the menu bar panel lists them, each with its AutoEQ wand (the
/// panel's, without "Open EQ Manager..."). The devices hidden from the panel are left out, and
/// listed dimmed while ⌥ is held.
///
/// Clicking a device opens the preset it uses: `onOpen` gets its ID, and the window decides
/// what happens to the preset shown; "View preset" shows on hover. While a preset is shown,
/// each device that doesn't use it has an Apply button, beside its wand, which makes it use that
/// preset, with its correction on. A check after a device's name marks the devices that use the
/// preset shown.
@MainActor
struct EQManagerDACMenuButton: View {
    let audioEngine: AudioEngine
    /// The preset shown, as saved: what a device gets. Nil when none is shown.
    let preset: AutoEQProfile?
    /// Unsaved changes are shown: a device would get the saved preset, not what is shown.
    let hasChanges: Bool
    /// Opens the preset with this ID, the one a device uses.
    let onOpen: (_ presetID: String) -> Void

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
                Label("DACs", systemImage: "hifispeaker")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .fixedSize()
        .help(menuHelp)
        .background(
            PopoverHost(
                isPresented: $isOpen,
                preferredColorScheme: appearance.swiftUIColorScheme,
                nsAppearance: appearance.nsAppearance
            ) {
                EQManagerDACList(
                    entries: list.shown,
                    hiddenCount: list.hiddenCount,
                    presetName: preset?.name,
                    hasChanges: hasChanges,
                    onOpen: { presetID in
                        isOpen = false
                        onOpen(presetID)
                    },
                    onApply: { deviceUID in
                        guard let preset else { return }
                        audioEngine.setAutoEQProfile(for: deviceUID, profileID: preset.id)
                    }
                )
                // The wands open dropdowns of their own, in the same appearance
                .environment(\.appearancePreference, appearance)
            }
        )
    }

    private var menuHelp: String {
        preset == nil
            ? "Open the preset an output device uses"
            : "Open the preset an output device uses, or make a device use this one"
    }

    /// The devices listed, in the panel's order, and how many hidden ones are left out (none
    /// while the dropdown is closed).
    private func entries() -> (shown: [EQManagerDACEntry], hiddenCount: Int) {
        guard isOpen else { return ([], 0) }
        let showsHidden = OptionKeyMonitor.shared.isOptionDown
        let defaultDeviceID = audioEngine.deviceVolumeMonitor.defaultDeviceID
        var shown: [EQManagerDACEntry] = []
        var hiddenCount = 0
        for device in audioEngine.prioritySortedOutputDevices where device.supportsAutoEQ {
            let isHidden = audioEngine.isOutputDeviceHiddenFromPanel(device)
            if isHidden && !showsHidden {
                hiddenCount += 1
                continue
            }
            let menu = AutoEQDeviceMenu(deviceUID: device.uid, audioEngine: audioEngine)
            let presetID = menu.selection?.profileID
            shown.append(EQManagerDACEntry(
                device: device,
                menu: menu,
                icon: DeviceIconResolver.displayIcon(
                    overrideSymbol: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid),
                    automatic: device.icon,
                    deviceName: device.name
                ),
                isDefault: device.id == defaultDeviceID,
                volumePluginName: volumePluginName(for: device),
                presetID: presetID,
                usesPreset: preset != nil && presetID == preset?.id,
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

/// A device of the DACs dropdown.
struct EQManagerDACEntry: Identifiable {
    let device: AudioDevice
    let menu: AutoEQDeviceMenu
    let icon: NSImage?
    let isDefault: Bool
    let volumePluginName: String?
    /// The device's AutoEQ preset, if it has one: clicking the device opens it.
    let presetID: String?
    /// The device's AutoEQ preset is the one shown.
    let usesPreset: Bool
    /// Hidden from the menu bar panel, listed while ⌥ is held.
    let isHidden: Bool

    var id: String { device.uid }
}

/// Content of the DACs dropdown.
private struct EQManagerDACList: View {
    let entries: [EQManagerDACEntry]
    let hiddenCount: Int
    /// Name of the preset shown, if any: the devices can be made to use it.
    let presetName: String?
    let hasChanges: Bool
    let onOpen: (_ presetID: String) -> Void
    let onApply: (_ deviceUID: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.top, DesignTokens.Spacing.xs)

            if presetName != nil && hasChanges {
                note("Save or discard your changes to apply the preset: a DAC gets the saved preset.")
            }

            if entries.isEmpty {
                note(hiddenCount > 0
                     ? "Every DAC that supports AutoEQ is hidden. Hold ⌥ to list them."
                     : "No connected output supports AutoEQ.")
                    .padding(.vertical, DesignTokens.Spacing.xs)
            }

            ForEach(entries) { entry in
                EQManagerDACRow(
                    entry: entry,
                    presetName: presetName,
                    canApply: !hasChanges,
                    onOpen: { if let id = entry.presetID { onOpen(id) } },
                    onApply: { onApply(entry.device.uid) }
                )
            }
        }
        .padding(DesignTokens.Spacing.xs)
        .frame(width: 320)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }

    private var title: String {
        guard let presetName else { return "Click a DAC to open its preset" }
        return "Click a DAC to open its preset, or apply “\(presetName)”"
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
/// wand, and the Apply button while a preset is shown that the device doesn't use.
private struct EQManagerDACRow: View {
    let entry: EQManagerDACEntry
    let presetName: String?
    let canApply: Bool
    let onOpen: () -> Void
    let onApply: () -> Void

    @State private var isHovered = false
    @State private var isApplyHovered = false

    /// Clicking the row opens the device's preset: it has one, and it isn't the one shown.
    private var opensPreset: Bool { entry.presetID != nil && !entry.usesPreset }

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
                            .accessibilityLabel("Uses the preset shown")
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

            if isHovered && opensPreset {
                Text("View preset")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            if let presetName, !entry.usesPreset {
                applyButton(presetName)
            }

            AutoEQPicker(menu: entry.menu, showsManagerButton: false)
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .hoverableRow()
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .opacity(entry.isHidden ? 0.5 : 1)
        .help(openHelp)
        .accessibilityAddTraits(.isButton)
    }

    /// An icon, the size of the wand beside it.
    private func applyButton(_ presetName: String) -> some View {
        Button(action: onApply) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(applyIconColor)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canApply)
        .onHover { isApplyHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isApplyHovered)
        .help(canApply
              ? "Apply “\(presetName)” to \(entry.device.name)"
              : "Save or discard your changes first")
        .accessibilityLabel("Apply “\(presetName)”")
    }

    private var applyIconColor: Color {
        guard canApply else { return DesignTokens.Colors.textTertiary }
        return isApplyHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault
    }

    private var openHelp: String {
        guard entry.presetID != nil else { return "\(entry.device.name) has no AutoEQ preset" }
        if entry.usesPreset { return "\(entry.device.name) uses the preset shown" }
        return "Open “\(entry.menu.profileName ?? "its preset")”, the preset of \(entry.device.name)"
    }
}
