// FineTune/Views/Rows/DeviceRow.swift
import SwiftUI

/// A row displaying a device with volume controls.
/// Used in the Output Devices section.
///
/// Volume mapping depends on the device's `volumeBackend`:
/// - **Hardware**: Identity mapping (slider == HAL scalar). CoreAudio's VirtualMainVolume
///   scalar is already audio-tapered by the driver — IOAudioLevelControl applies a dB curve
///   by default (see `setLinearScale()` in IOAudioLevelControl.h). Empirically confirmed:
///   scalar 0.50 → −50 dB, scalar 0.10 → −90 dB (100 dB range, linear-in-dB).
/// - **DDC**: Identity mapping (slider == DDC 0–100 / 100). DDC writes VCP 0x62 (Audio
///   Speaker Volume) as an integer 0–100 directly to the monitor via I2C, bypassing the HAL
///   entirely. The monitor's firmware handles perceptual mapping internally. Identity matches
///   the OSD values users see on the physical display. MonitorControl uses the same approach.
/// - **Software**: VolumeMapping x² curve. Software gain is a linear PCM amplitude multiplier
///   that needs perceptual scaling (dr-lex.be, Discord perceptual).
///
/// See: IOAudioLevelControl.h, MCCS VCP 0x62, empirical ScalarToDecibels measurement.
///
/// While ⌥ is held, the slider and percentage edit the device's master volume instead (the
/// software gain FineTune applies on top of the device's own volume, whatever its backend,
/// with the master slider's x² curve), without making the device the default output.
struct DeviceRow: View {
    let device: AudioDevice
    let isDefault: Bool
    let volume: Float
    let isMuted: Bool
    /// The device's volume backend. Determines which slider ↔ value mapping to use.
    let volumeBackend: VolumeControlTier
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void

    // AutoEQ (all optional — existing call sites work without them)
    let autoEQProfileName: String?
    let autoEQEnabled: Bool
    let onAutoEQToggle: ((Bool) -> Void)?
    let autoEQProfileManager: AutoEQProfileManager?
    let autoEQSelection: AutoEQSelection?
    let autoEQFavoriteIDs: Set<String>
    let onAutoEQSelect: ((AutoEQProfile?) -> Void)?
    let onAutoEQImport: (() -> Void)?
    let onAutoEQToggleFavorite: ((String) -> Void)?
    let autoEQImportError: String?
    let autoEQPreampEnabled: Bool
    let onAutoEQPreampToggle: (() -> Void)?
    let isFocused: Bool
    let iconOverrideSymbol: String?

    // Master volume (optional — without `onMasterVolumeChange` ⌥ does nothing)
    let masterVolume: Float
    let onMasterVolumeChange: ((Float) -> Void)?
    let optionKeyEditsMasterVolume: Bool

    @State private var sliderValue: Double
    /// Slider position of the master volume, mirrored like `sliderValue` for the device volume.
    @State private var masterSliderValue: Double
    @State private var isUpdatingMasterFromModel = false
    /// Which volume the current drag edits (true: master volume), fixed when the drag starts
    /// so pressing or releasing ⌥ mid-drag doesn't swap the slider under the pointer.
    @State private var dragEditsMaster: Bool?
    /// Same for typing in the percentage: fixed when the edit starts, so ⌥ can be released to
    /// type, and kept a moment after it ends so the slider is seen reaching the typed value.
    @State private var percentageEditsMaster: Bool?
    @State private var percentageEditRelease: Task<Void, Never>?
    @State private var isEditing = false
    @State private var suppressSliderAutoUnmute = false
    /// Suppresses write-back when slider is being synced from a device volume change.
    /// Breaks the quantization feedback loop on USB DACs with discrete dB steps.
    @State private var isUpdatingSliderFromDevice = false

    /// The displayed percentage value, matching EditablePercentage's formula.
    /// Used for icon and unmute logic so visual state stays consistent with the label.
    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }

    /// Show muted icon when system muted OR displayed volume is 0%.
    /// Uses percentage threshold (not exact sliderValue == 0) because SwiftUI Slider
    /// and volume clamping can leave sliderValue at tiny non-zero values (e.g. 0.003)
    /// that display as "0%" but fail exact Double equality.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    /// Default slider position to restore when unmuting from 0 (50%)
    private let defaultUnmuteVolume: Double = 0.5

    /// True while the slider and percentage show the master volume instead of the device volume.
    private var showsMasterVolume: Bool {
        guard optionKeyEditsMasterVolume, onMasterVolumeChange != nil else { return false }
        return dragEditsMaster ?? percentageEditsMaster ?? OptionKeyMonitor.shared.isOptionDown
    }

    /// The slider position the controls currently edit. Resolved when read or written, so the
    /// scroll-wheel monitor installed on hover follows ⌥ too.
    private var activeSliderValue: Binding<Double> {
        Binding(
            get: { showsMasterVolume ? masterSliderValue : sliderValue },
            set: { newValue in
                if showsMasterVolume {
                    masterSliderValue = newValue
                } else {
                    sliderValue = newValue
                }
            }
        )
    }

    /// How long the slider keeps showing the master volume after a typed edit ends.
    private static let percentageEditReleaseDelay: Duration = .milliseconds(900)

    private var displayIcon: NSImage? {
        DeviceIconResolver.displayIcon(
            overrideSymbol: iconOverrideSymbol,
            automatic: device.icon,
            deviceName: device.name
        )
    }

    init(
        device: AudioDevice,
        isDefault: Bool,
        volume: Float,
        isMuted: Bool,
        volumeBackend: VolumeControlTier = .hardware,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        autoEQProfileName: String? = nil,
        autoEQEnabled: Bool = false,
        onAutoEQToggle: ((Bool) -> Void)? = nil,
        autoEQProfileManager: AutoEQProfileManager? = nil,
        autoEQSelection: AutoEQSelection? = nil,
        autoEQFavoriteIDs: Set<String> = [],
        onAutoEQSelect: ((AutoEQProfile?) -> Void)? = nil,
        onAutoEQImport: (() -> Void)? = nil,
        onAutoEQToggleFavorite: ((String) -> Void)? = nil,
        autoEQImportError: String? = nil,
        autoEQPreampEnabled: Bool = true,
        onAutoEQPreampToggle: (() -> Void)? = nil,
        isFocused: Bool = false,
        iconOverrideSymbol: String? = nil,
        masterVolume: Float = 1.0,
        onMasterVolumeChange: ((Float) -> Void)? = nil,
        optionKeyEditsMasterVolume: Bool = false
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.isMuted = isMuted
        self.volumeBackend = volumeBackend
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.autoEQProfileName = autoEQProfileName
        self.autoEQEnabled = autoEQEnabled
        self.onAutoEQToggle = onAutoEQToggle
        self.autoEQProfileManager = autoEQProfileManager
        self.autoEQSelection = autoEQSelection
        self.autoEQFavoriteIDs = autoEQFavoriteIDs
        self.onAutoEQSelect = onAutoEQSelect
        self.onAutoEQImport = onAutoEQImport
        self.onAutoEQToggleFavorite = onAutoEQToggleFavorite
        self.autoEQImportError = autoEQImportError
        self.autoEQPreampEnabled = autoEQPreampEnabled
        self.onAutoEQPreampToggle = onAutoEQPreampToggle
        self.isFocused = isFocused
        self.iconOverrideSymbol = iconOverrideSymbol
        self.masterVolume = masterVolume
        self.onMasterVolumeChange = onMasterVolumeChange
        self.optionKeyEditsMasterVolume = optionKeyEditsMasterVolume
        self._sliderValue = State(initialValue: Self.volumeToSlider(volume, backend: volumeBackend))
        self._masterSliderValue = State(initialValue: VolumeMapping.gainToSlider(masterVolume))
    }

    var body: some View {
        deviceHeader
            .contentShape(Rectangle())
            .onTapGesture {
                // Whole-row tap sets this device as default. Inner controls
                // (volume slider, mute button, AutoEQ picker, percent field)
                // are Button/Slider/TextField subviews that capture their
                // own gestures, so they do not propagate to this handler.
                // Mirrors the macOS Sound submenu pattern.
                if !isDefault {
                    onSetDefault()
                }
            }
            .hoverableRow(isFocused: isFocused)
            .onAppear { OptionKeyMonitor.shared.start() }
            .onHover { hovering in
                if hovering { OptionKeyMonitor.shared.refresh() }
            }
    }

    // MARK: - Device Header

    private var deviceHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Tinted badge replaces the prior leading RadioButton.
            // Selection is now signalled by accent-colored gradient on the
            // badge plus bold device name; the row-level gesture in `body`
            // handles tap-to-set-default.
            DeviceBadge(icon: displayIcon, isSelected: isDefault)

            // Device name + optional AutoEQ profile subtitle + AutoEQ picker
            HStack(spacing: DesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)
                        .help(device.name)

                    if let subtitle = Self.autoEQSubtitle(profileName: autoEQProfileName, isEnabled: autoEQEnabled) {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // AutoEQ picker inside the name area so slider length stays consistent
                if device.supportsAutoEQ,
                   let profileManager = autoEQProfileManager,
                   let onSelect = onAutoEQSelect,
                   let onImport = onAutoEQImport {
                    AutoEQPicker(
                        profileManager: profileManager,
                        profileName: autoEQProfileName,
                        selection: autoEQSelection,
                        favoriteIDs: autoEQFavoriteIDs,
                        onSelect: onSelect,
                        onImport: onImport,
                        onToggleFavorite: { id in onAutoEQToggleFavorite?(id) },
                        importError: autoEQImportError,
                        isCorrectionEnabled: autoEQEnabled,
                        onCorrectionToggle: onAutoEQToggle,
                        preampEnabled: autoEQPreampEnabled,
                        onPreampToggle: onAutoEQPreampToggle
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Mute button
            MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                if showMutedIcon {
                    // Unmute: restore to default if displayed as 0%
                    if displayedPercentage == 0 {
                        suppressSliderAutoUnmute = isMuted
                        sliderValue = defaultUnmuteVolume
                    }
                    if isMuted {
                        onMuteToggle()  // Toggle system mute
                    }
                } else {
                    // Mute
                    onMuteToggle()  // Toggle system mute
                }
            }

            // Volume slider (Liquid Glass): the device volume, or its master volume while ⌥ is held
            LiquidGlassSlider(
                value: activeSliderValue,
                fillColor: showsMasterVolume ? DesignTokens.Colors.masterVolumeOption : DesignTokens.Colors.accentPrimary,
                onEditingChanged: { editing in
                    if editing {
                        let editsMaster = showsMasterVolume
                        dragEditsMaster = editsMaster
                        isEditing = !editsMaster
                    } else {
                        dragEditsMaster = nil
                        isEditing = false
                    }
                }
            )
            .opacity(showMutedIcon && !showsMasterVolume ? 0.5 : 1.0)
            .onChange(of: sliderValue) { _, newValue in
                // Skip write-back when syncing from device (breaks USB DAC quantization spiral)
                if isUpdatingSliderFromDevice {
                    isUpdatingSliderFromDevice = false
                    return
                }
                onVolumeChange(Self.sliderToVolume(newValue, backend: volumeBackend))
                if suppressSliderAutoUnmute {
                    suppressSliderAutoUnmute = false
                    return
                }
                // Auto-unmute when slider moved while muted
                if isMuted && newValue > 0 {
                    onMuteToggle()
                }
            }
            .onChange(of: masterSliderValue) { _, newValue in
                if isUpdatingMasterFromModel {
                    isUpdatingMasterFromModel = false
                    return
                }
                onMasterVolumeChange?(VolumeMapping.sliderToGain(newValue))
            }
            .scrollWheelStep(activeSliderValue, in: 0.0...1.0)

            // Editable volume percentage (of the master volume while ⌥ is held)
            EditablePercentage(
                percentage: Binding(
                    get: { Int(round(activeSliderValue.wrappedValue * 100)) },
                    set: { newValue in
                        // Typed values glide the slider there instead of jumping
                        withAnimation(.easeOut(duration: 0.25)) {
                            activeSliderValue.wrappedValue = Double(newValue) / 100.0
                        }
                    }
                ),
                range: 0...100,
                isRowFocused: isFocused,
                onEditingChanged: { editing in
                    percentageEditRelease?.cancel()
                    percentageEditRelease = nil
                    if editing {
                        // Keeps the target of an edit that starts during the release delay
                        if percentageEditsMaster == nil {
                            percentageEditsMaster = showsMasterVolume
                        }
                    } else {
                        percentageEditRelease = Task { @MainActor in
                            try? await Task.sleep(for: Self.percentageEditReleaseDelay)
                            guard !Task.isCancelled else { return }
                            percentageEditsMaster = nil
                            percentageEditRelease = nil
                        }
                    }
                }
            )
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            let newSlider = Self.volumeToSlider(newValue, backend: volumeBackend)
            guard newSlider != sliderValue else { return }
            isUpdatingSliderFromDevice = true
            sliderValue = newSlider
        }
        .onDisappear {
            percentageEditRelease?.cancel()
            percentageEditRelease = nil
            percentageEditsMaster = nil
        }
        .onChange(of: masterVolume) { _, newValue in
            // Changed from the master slider, or written back from our own edit
            guard dragEditsMaster != true else { return }
            let newSlider = VolumeMapping.gainToSlider(newValue)
            guard newSlider != masterSliderValue else { return }
            isUpdatingMasterFromModel = true
            masterSliderValue = newSlider
        }
    }
}

extension DeviceRow {
    // MARK: - Volume Mapping

    static func volumeToSlider(_ volume: Float, backend: VolumeControlTier) -> Double {
        VolumeMapping.sliderFraction(forSystemGain: volume, tier: backend)
    }

    static func sliderToVolume(_ slider: Double, backend: VolumeControlTier) -> Float {
        VolumeMapping.systemGain(forSliderFraction: slider, tier: backend)
    }

    // MARK: - Subtitle

    static func autoEQSubtitle(profileName: String?, isEnabled: Bool) -> String? {
        guard let profileName else { return nil }
        return isEnabled ? profileName : "\(profileName) (off)"
    }
}

// MARK: - Previews

#Preview("Device Row - Default") {
    PreviewContainer {
        VStack(spacing: 0) {
            DeviceRow(
                device: MockData.sampleDevices[0],
                isDefault: true,
                volume: 0.75,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[1],
                isDefault: false,
                volume: 1.0,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[2],
                isDefault: false,
                volume: 0.5,
                isMuted: true,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )
        }
    }
}
