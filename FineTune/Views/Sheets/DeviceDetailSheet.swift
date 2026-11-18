// FineTune/Views/Sheets/DeviceDetailSheet.swift
import SwiftUI
import os

@MainActor
struct DeviceDetailSheet: View {
    /// The volume plugin menu of a device: no plugin, the plugins written for the device, and,
    /// while ⌥ is held, the others
    struct PluginMenu {
        struct Option: Identifiable, Equatable {
            /// The plugin's id, or `PluginMenu.noPluginID`
            let id: String
            let title: String
            /// Written for the device. Choosing another plugin asks first.
            let isCompatible: Bool
        }

        static let noPluginID = ""

        /// No plugin, the plugins written for the device, then the chosen plugin if it is neither
        let options: [Option]
        /// The plugins that aren't written for the device, listed while ⌥ is held
        let otherOptions: [Option]
        let selectedID: String
        /// What the plugin does to the device, or what went wrong
        let caption: String?
        let captionIsWarning: Bool
        let onSelect: (String) -> Void

        /// - Parameters:
        ///   - plugins: the usable plugins, in the order they take new DACs
        ///   - compatibleIDs: those written for the device
        ///   - choice: the device's choice, nil while it has none
        ///   - activePluginID: the plugin that drives the device now
        ///   - problem: why the chosen plugin doesn't drive the device, or what went wrong
        static func make(
            plugins: [(id: String, name: String)],
            compatibleIDs: [String],
            choice: VolumePluginChoice?,
            activePluginID: String?,
            problem: String?,
            onSelect: @escaping (String) -> Void
        ) -> PluginMenu {
            let compatible = Set(compatibleIDs)
            var options = [Option(id: noPluginID, title: "None", isCompatible: true)]
            var others: [Option] = []
            for plugin in plugins {
                if compatible.contains(plugin.id) {
                    options.append(Option(id: plugin.id, title: plugin.name, isCompatible: true))
                } else {
                    others.append(Option(id: plugin.id, title: plugin.name, isCompatible: false))
                }
            }

            var selectedID = noPluginID
            if case .plugin(let pluginID)? = choice {
                selectedID = pluginID
            }
            // The chosen plugin stays in view without ⌥, even when it isn't written for the
            // device, or is gone from the plugins folder
            if !options.contains(where: { $0.id == selectedID }) {
                if let index = others.firstIndex(where: { $0.id == selectedID }) {
                    options.append(others.remove(at: index))
                } else {
                    options.append(Option(id: selectedID, title: "\(selectedID) (missing)", isCompatible: false))
                }
            }

            let caption: String?
            var isWarning = false
            if let problem {
                caption = problem
                isWarning = true
            } else if selectedID == noPluginID {
                if !compatibleIDs.isEmpty {
                    caption = "A plugin can set this DAC's own volume."
                } else if !others.isEmpty {
                    caption = "No plugin is written for this device. Hold ⌥ to list the others."
                } else {
                    caption = nil
                }
            } else if !compatible.contains(selectedID) {
                caption = "This plugin isn't written for this device. Choose None if it misbehaves."
                isWarning = true
            } else if activePluginID == selectedID {
                caption = "Sets the DAC's own volume. Choose None if the DAC misbehaves."
            } else {
                caption = "Starting the plugin…"
            }

            return PluginMenu(
                options: options,
                otherOptions: others,
                selectedID: selectedID,
                caption: caption,
                captionIsWarning: isWarning,
                onSelect: onSelect
            )
        }
    }

    let device: AudioDevice
    let transportType: TransportType
    let autoDetectedTier: VolumeControlTier
    let currentOverride: VolumeControlTier?
    let onOverrideChange: (VolumeControlTier?) -> Void
    let onDismiss: () -> Void
    /// Keep-alive (optional — without `onKeepAliveChange` the sheet shows no keep-alive row)
    let keepAliveEnabled: Bool
    let keepAliveStatus: DeviceKeepAliveService.Status?
    let onKeepAliveChange: ((Bool) -> Void)?
    /// Without it, the sheet shows no volume plugin row
    let pluginMenu: PluginMenu?

    @State private var viewModel: DeviceInspectorViewModel
    /// A plugin not written for the device, picked in the menu, waiting for the user to confirm it
    @State private var pendingPluginOption: PluginMenu.Option?

    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "DeviceDetailSheet")

    init(
        device: AudioDevice,
        transportType: TransportType,
        autoDetectedTier: VolumeControlTier,
        currentOverride: VolumeControlTier?,
        onOverrideChange: @escaping (VolumeControlTier?) -> Void,
        onDismiss: @escaping () -> Void,
        keepAliveEnabled: Bool = false,
        keepAliveStatus: DeviceKeepAliveService.Status? = nil,
        onKeepAliveChange: ((Bool) -> Void)? = nil,
        pluginMenu: PluginMenu? = nil
    ) {
        self.device = device
        self.transportType = transportType
        self.autoDetectedTier = autoDetectedTier
        self.currentOverride = currentOverride
        self.onOverrideChange = onOverrideChange
        self.onDismiss = onDismiss
        self.keepAliveEnabled = keepAliveEnabled
        self.keepAliveStatus = keepAliveStatus
        self.onKeepAliveChange = onKeepAliveChange
        self.pluginMenu = pluginMenu
        self._viewModel = State(
            initialValue: DeviceInspectorViewModel(
                deviceID: device.id,
                uid: device.uid,
                transportType: transportType
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            DeviceInspectorInfoGrid(
                info: viewModel.info,
                onSampleRateSelected: { rate in
                    viewModel.selectSampleRate(rate)
                }
            )

            if let error = viewModel.sampleRateError {
                errorBanner(error)
            }

            if let hogLine = DeviceInspectorInfo.formatHogModeOwner(
                viewModel.info.hogModeOwner,
                processName: viewModel.hogModeOwnerName
            ) {
                separator
                hogModeRow(hogLine)
            }

            // Always shown, so every device says how its volume is set
            separator
            if Self.canChooseSoftware(autoTier: autoDetectedTier) {
                softwareToggle
            } else {
                softwareOnlyRow
            }
            calloutText

            if let pluginMenu {
                separator
                pluginRow(pluginMenu)
                if let pendingPluginOption {
                    incompatiblePluginConfirmation(pendingPluginOption, menu: pluginMenu)
                } else if let caption = pluginMenu.caption {
                    pluginCaption(caption, isWarning: pluginMenu.captionIsWarning)
                }
            }

            if let onKeepAliveChange {
                separator
                keepAliveToggle(onChange: onKeepAliveChange)
                keepAliveCallout
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .onAppear {
            viewModel.start()
            // ⌥ lists the plugins that aren't written for the device
            OptionKeyMonitor.shared.start()
        }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - Auto badge

    private var autoBadge: some View {
        Text("Auto: \(Self.tierDisplayName(autoDetectedTier))")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(DesignTokens.Colors.glassFillStrong)
            )
            .accessibilityLabel("Auto-detected volume control: \(Self.tierDisplayName(autoDetectedTier))")
    }

    // MARK: - Separator

    private var separator: some View {
        Rectangle()
            .fill(DesignTokens.Colors.separator)
            .frame(height: 0.5)
    }

    // MARK: - Hog mode row

    private func hogModeRow(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Error banner

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.mutedIndicator)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Software Toggle

    @ViewBuilder
    private var softwareToggle: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            autoBadge

            Text("Use FineTune's software volume")
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Toggle("", isOn: useSoftwareBinding)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
    }

    /// For a device with no other backend: the software volume is the only one, so there is
    /// nothing to switch.
    private var softwareOnlyRow: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            autoBadge

            Text("Volume set by FineTune")
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer(minLength: 0)
        }
    }

    /// OFF writes `nil` (clears the pin, re-runs auto-detect); ON pins `.software`.
    private var useSoftwareBinding: Binding<Bool> {
        Binding(
            get: { currentOverride == .some(.software) },
            set: { newValue in
                Self.logger.debug("Toggle flipped: uid=\(device.uid, privacy: .public) useSoftware=\(newValue, privacy: .public)")
                onOverrideChange(newValue ? .some(.software) : nil)
            }
        )
    }

    // MARK: - Callout

    private var calloutText: some View {
        Text(Self.canChooseSoftware(autoTier: autoDetectedTier)
             ? "Turn on only if the volume slider doesn't work. FineTune remembers this for each device."
             : "This device has no volume control of its own that FineTune can use.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Volume Plugin

    private func pluginRow(_ menu: PluginMenu) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            Text("Volume plugin")
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer(minLength: DesignTokens.Spacing.sm)

            pluginDropdown(menu)
        }
    }

    private func pluginDropdown(_ menu: PluginMenu) -> some View {
        let items = OptionKeyMonitor.shared.isOptionDown ? menu.options + menu.otherOptions : menu.options
        // Only None to pick: say so, under it
        let footnote: String? = items.count == 1 ? "No plugin available for this device" : nil
        return DropdownMenu(
            items: items,
            selectedItem: items.first { $0.id == menu.selectedID },
            maxVisibleItems: 8,
            width: 160,
            popoverWidth: 220,
            footnote: footnote,
            onSelect: { option in
                guard option.id != menu.selectedID else { return }
                if option.isCompatible {
                    pendingPluginOption = nil
                    menu.onSelect(option.id)
                } else {
                    pendingPluginOption = option
                }
            }
        ) { selected in
            Text(selected?.title ?? "None")
        } itemContent: { option, isSelected in
            pluginOptionLabel(option, isSelected: isSelected)
        }
    }

    /// A plugin not written for the device is paler, after a warning sign
    private func pluginOptionLabel(_ option: PluginMenu.Option, isSelected: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if !option.isCompatible {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            Text(option.title)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.xs)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .opacity(option.isCompatible ? 1 : 0.55)
    }

    private func pluginCaption(_ text: String, isWarning: Bool) -> some View {
        Text(text)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(isWarning ? DesignTokens.Colors.mutedIndicator : DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Asks in the details themselves: a dialog would take the focus from the menu bar panel,
    /// which then closes
    private func incompatiblePluginConfirmation(_ option: PluginMenu.Option, menu: PluginMenu) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Text("Use “\(option.title)” on this device?")
                    .font(DesignTokens.Typography.pickerText.weight(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
            }

            Text("This plugin isn't written for this device: it will send it commands meant for another one, which can set it to full volume, or leave it stuck until you unplug it. Go on only if you know what you're doing, with your headphones off.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Spacer(minLength: 0)
                Button("Cancel") { pendingPluginOption = nil }
                Button("Use Anyway") {
                    pendingPluginOption = nil
                    menu.onSelect(option.id)
                }
            }
            .controlSize(.small)
        }
        .padding(DesignTokens.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignTokens.Colors.glassFillStrong)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .systemOrange).opacity(0.6), lineWidth: 0.5)
        }
    }

    // MARK: - Keep-Alive

    private func keepAliveToggle(onChange: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text("Keep stream alive")
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            if keepAliveEnabled, let keepAliveStatus {
                keepAliveStatusBadge(keepAliveStatus)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Toggle("", isOn: Binding(get: { keepAliveEnabled }, set: { onChange($0) }))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
    }

    private func keepAliveStatusBadge(_ status: DeviceKeepAliveService.Status) -> some View {
        Text(Self.keepAliveStatusText(status))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(status == .running ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.mutedIndicator)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(DesignTokens.Colors.glassFillStrong)
            )
            .help(Self.keepAliveStatusHelp(status))
    }

    private var keepAliveCallout: some View {
        Text("Streams silence so the device never sleeps. For DACs that click or pop.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func keepAliveStatusText(_ status: DeviceKeepAliveService.Status) -> String {
        switch status {
        case .starting: return "Starting"
        case .running: return "Running"
        case .blockedByHogMode: return "Blocked"
        case .failed: return "Retrying"
        }
    }

    static func keepAliveStatusHelp(_ status: DeviceKeepAliveService.Status) -> String {
        switch status {
        case .starting: return "Opening the device's stream"
        case .running: return "The device is streaming silence"
        case .blockedByHogMode(let pid): return "Another app (PID \(pid)) holds the device in exclusive mode. FineTune retries until it is released."
        case .failed(let code): return "The device refused the stream (error \(code)). FineTune keeps retrying."
        }
    }

    // MARK: - Helpers

    static func tierDisplayName(_ tier: VolumeControlTier) -> String {
        switch tier {
        case .hardware: return "Hardware"
        case .ddc: return "DDC"
        case .plugin: return "Plugin"
        case .software: return "Software"
        }
    }

    /// The toggle is shown unless auto-tier is already `.software`: there is no other backend to
    /// switch from. The row then shows the "Auto: Software" badge without a switch.
    static func canChooseSoftware(autoTier: VolumeControlTier) -> Bool {
        autoTier != .software
    }
}
