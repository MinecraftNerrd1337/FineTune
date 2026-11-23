// FineTune/Views/Settings/Tabs/AudioTab.swift
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted output devices for the system-sounds picker.
    @State private var sortedOutputDevices: [AudioDevice] = []
    @State private var isVolumePluginsSheetPresented = false

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                devicesSection
                autoEQSection
                presetsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { oldValue, newValue in
            if !oldValue && newValue {
                audioEngine.handleInputLockEnabled()
            }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.callPassthroughEnabled) { _, _ in
            audioEngine.reconcileCallPassthrough()
        }
        .onChange(of: settings.appSettings.perDeviceMixingEnabled) { _, _ in
            audioEngine.reconcileRoutingMode()
        }
        .onChange(of: settings.appSettings.startGuardEnabled) { _, newValue in
            audioEngine.setStartGuardEnabled(newValue)
        }
        .onChange(of: settings.appSettings.autoEQLevelMatchEnabled) { _, _ in
            audioEngine.reapplyAllAutoEQ()
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Default Volume",
                description: "Initial volume for new apps"
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: 280
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Loudness Compensation",
                description: "Boost low frequencies at low volume"
            ) {
                Toggle("", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Skip Apps on Calls",
                description: "Leave apps untouched while they use the microphone — fixes quiet call audio and echo"
            ) {
                Toggle("", isOn: $settings.appSettings.callPassthroughEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection("Devices") {
            SettingsRow(
                "Lock Input Device",
                description: "Prevent auto-switching when devices connect"
            ) {
                Toggle("", isOn: $settings.appSettings.lockInputDevice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Master Volume with ⌥",
                description: "Hold ⌥ on an output device's slider to adjust its master volume without switching to it"
            ) {
                Toggle("", isOn: $settings.appSettings.masterVolumeOptionKeyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Mix Apps per Device",
                description: "Play the apps of each stereo output through one stream, so AutoEQ corrects their sum once per device. Multichannel and multi-device outputs stay per app"
            ) {
                Toggle("", isOn: $settings.appSettings.perDeviceMixingEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Protect App Starts",
                description: "Keep an app silent for the instant before FineTune takes it over, so its sound never starts without FineTune's volume"
            ) {
                Toggle("", isOn: $settings.appSettings.startGuardEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            #if !APP_STORE
            SettingsRowDivider()
            volumePluginsRow
            #endif
            SettingsRowDivider()
            SettingsRow(
                "System Sounds",
                description: "Where alerts and effects play"
            ) {
                SystemSoundsDevicePicker(
                    devices: sortedOutputDevices,
                    deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
                    selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                    isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                    onDeviceSelected: { deviceUID in
                        if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                            deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                        }
                    },
                    onSelectFollowDefault: {
                        deviceVolumeMonitor.setSystemFollowDefault()
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Alert Volume",
                description: "Volume for alerts and notifications"
            ) {
                VolumeSlider(
                    Binding(
                        get: { deviceVolumeMonitor.alertVolume },
                        set: { deviceVolumeMonitor.setAlertVolume($0) }
                    ),
                    range: 0...1,
                    width: 280
                )
            }
            .task {
                // No CoreAudio listener for alert volume — must poll via AppleScript.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }
        }
    }

    // MARK: - Volume Plugins

    #if !APP_STORE
    /// The plugins themselves are listed in a sheet, so the tab doesn't grow with each one
    private var volumePluginsRow: some View {
        let controller = audioEngine.volumePlugins
        return SettingsRow(
            "Volume Plugins",
            description: Self.volumePluginsSummary(controller.plugins.map { controller.status(of: $0) })
        ) {
            Button("Manage…") { isVolumePluginsSheetPresented = true }
                .controlSize(.small)
        }
        // Picks up plugins added since launch; restarts nothing when the folder didn't change
        .onAppear { controller.reload() }
        .sheet(isPresented: $isVolumePluginsSheetPresented) {
            VolumePluginsSheet(controller: controller) { isVolumePluginsSheetPresented = false }
                .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        }
    }

    /// The row's description: what plugins are for, and what the installed ones do
    static func volumePluginsSummary(_ statuses: [VolumePluginController.Status]) -> String {
        let purpose = "Set the hardware volume of DACs macOS can't, with the DAC's own commands"
        guard !statuses.isEmpty else { return "\(purpose). None installed" }
        var deviceNames: [String] = []
        var problems = 0
        for status in statuses {
            switch status {
            case .active(let names): deviceNames += names
            case .invalid, .failed: problems += 1
            case .unused: break
            }
        }
        var parts = [statuses.count == 1 ? "1 installed" : "\(statuses.count) installed"]
        if !deviceNames.isEmpty { parts.append("in use on \(deviceNames.sorted().joined(separator: ", "))") }
        if problems > 0 { parts.append(problems == 1 ? "1 with a problem" : "\(problems) with a problem") }
        return "\(purpose). \(parts.joined(separator: ", "))"
    }

    static func volumePluginDescription(_ plugin: VolumePluginFile, status: VolumePluginController.Status) -> String {
        var lines: [String] = []
        switch status {
        case .invalid(let error):
            lines.append("Can't be loaded: \(error)")
        case .unused:
            lines.append("Not in use")
        case .active(let deviceNames):
            lines.append("Sets the volume of \(deviceNames.joined(separator: ", "))")
        case .failed(let error):
            lines.append(error)
        }
        if let summary = plugin.manifest?.description, !summary.isEmpty {
            lines.append(summary)
        }
        var credits: [String] = []
        if let author = plugin.manifest?.author, !author.isEmpty { credits.append("By \(author)") }
        if let version = plugin.manifest?.version, !version.isEmpty { credits.append("version \(version)") }
        if !credits.isEmpty {
            lines.append(credits.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
    #endif

    // MARK: - AutoEQ

    private var autoEQSection: some View {
        SettingsSection("AutoEQ") {
            SettingsRow(
                "Same Loudness with Correction Off",
                description: "With a device's correction off, add the level its curve takes away or adds to the preamp, so turning the correction off and on keeps the same loudness. Turning Preamp off turns it off too. The preset and its preamp are left as they are"
            ) {
                Toggle("", isOn: $settings.appSettings.autoEQLevelMatchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - EQ Manager Presets

    private var presetsSection: some View {
        SettingsSection("EQ Manager Presets") {
            SettingsRow(
                "Ask Before Saving",
                description: "Confirm before a save replaces the stored version of a preset or template"
            ) {
                Toggle("", isOn: $settings.appSettings.confirmPresetSaves)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Versions Kept",
                description: "Earlier versions kept for each preset, to restore them from the EQ Manager. Lowering it drops the oldest versions of a preset at its next save."
            ) {
                Stepper(value: $settings.appSettings.presetHistoryLimit, in: AutoEQPresetHistoryStore.limitRange) {
                    Text(settings.appSettings.presetHistoryLimit == 0 ? "Off" : "\(settings.appSettings.presetHistoryLimit)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .controlSize(.small)
            }
        }
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}

// MARK: - Volume Plugins Sheet

#if !APP_STORE
/// Every plugin in the plugins folder, with what it does and whether it takes new DACs
@MainActor
struct VolumePluginsSheet: View {
    let controller: VolumePluginController
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Volume Plugins")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text("A plugin sets a DAC's hardware volume by sending it the DAC's own commands. Choose a DAC's plugin in its details, or let a plugin take the new DACs it is written for. Use only plugins you trust.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            pluginList

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Open Folder") { controller.revealPluginsFolder() }
                Button("Reload") { controller.reload(force: true) }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 520, height: 440)
        // Picks up a plugin added while Settings was open
        .onAppear { controller.reload() }
    }

    private var pluginList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if controller.plugins.isEmpty {
                    Text("No plugins yet. Put .finetuneplugin files in the plugins folder, then click Reload.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                ForEach(controller.plugins) { plugin in
                    if plugin.id != controller.plugins.first?.id {
                        SettingsRowDivider()
                    }
                    row(for: plugin)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func row(for plugin: VolumePluginFile) -> some View {
        let description = AudioTab.volumePluginDescription(plugin, status: controller.status(of: plugin))
        let takesNewDevices = Binding(
            get: { controller.takesNewDevices(plugin.id) },
            set: { controller.setTakesNewDevices($0, for: plugin.id) }
        )
        return SettingsRow(plugin.name, description: description) {
            if plugin.isUsable {
                Toggle(isOn: takesNewDevices) {
                    Text("New DACs")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Use this plugin for the DACs it is written for that FineTune hasn't seen yet. A DAC that is already set keeps its plugin, or none.")
            }
        }
    }
}
#endif
