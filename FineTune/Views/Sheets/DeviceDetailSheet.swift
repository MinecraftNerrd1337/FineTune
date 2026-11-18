// FineTune/Views/Sheets/DeviceDetailSheet.swift
import SwiftUI
import os

@MainActor
struct DeviceDetailSheet: View {
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

    @State private var viewModel: DeviceInspectorViewModel

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
        onKeepAliveChange: ((Bool) -> Void)? = nil
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
        .onAppear { viewModel.start() }
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
