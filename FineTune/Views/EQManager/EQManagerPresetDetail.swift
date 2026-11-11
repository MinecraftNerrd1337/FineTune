// FineTune/Views/EQManager/EQManagerPresetDetail.swift
import SwiftUI

/// The selected preset: attributes and preamp on the left, response graph and bands on the right.
/// Fields become editable when the editor is in edit mode.
@MainActor
struct EQManagerPresetDetail: View {
    let editor: EQManagerEditor

    @State private var selectedBand: Int?
    @State private var scaleDB: Double = 12
    /// Latency of the preset's linear-phase filter in milliseconds; nil while it is computed.
    @State private var latencyMS: Double?

    private var preset: AutoEQProfile { editor.draft }
    private var isEditing: Bool { editor.isEditing }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    presetSection
                    preampSection
                }
                .padding(.bottom, DesignTokens.Spacing.sm)
            }
            .scrollIndicators(.never)
            .frame(width: 280)

            VStack(spacing: DesignTokens.Spacing.sm) {
                graphHeader
                EQResponseGraph(
                    profile: preset,
                    scaleDB: scaleDB,
                    selectedBand: $selectedBand,
                    isEditable: isEditing,
                    onDragBegan: { editor.beginGesture() },
                    onDrag: { band, frequency, gain in
                        editor.updateGesture { profile in
                            guard profile.filters.indices.contains(band) else { return }
                            profile.filters[band].frequency = frequency
                            profile.filters[band].gainDB = gain
                        }
                    },
                    onDragEnded: { editor.endGesture() }
                )
                .frame(height: 220)

                bandsSection
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .onChange(of: preset.id, initial: true) { _, _ in
            selectedBand = nil
            scaleDB = Self.needsWideScale(preset) ? 24 : 12
        }
        .onChange(of: preset.filters.count) { _, count in
            if let band = selectedBand, band >= count { selectedBand = count > 0 ? count - 1 : nil }
        }
        .task(id: LatencyKey(preset)) {
            // Designing the filter takes a few milliseconds: wait until edits pause
            latencyMS = nil
            guard preset.effectiveEngine == .linearPhaseFIR, preset.hasCorrection else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            latencyMS = FIRKernelCache.latencyMilliseconds(of: preset, sampleRate: AutoEQResponse.defaultSampleRate)
        }
    }

    /// What the latency of a preset depends on.
    private struct LatencyKey: Equatable {
        let engine: AutoEQCorrectionEngine
        let filters: [AutoEQFilter]
        let curve: [AutoEQCurvePoint]
        let baseRate: Double

        init(_ preset: AutoEQProfile) {
            engine = preset.effectiveEngine
            // Only the linear-phase filter has a latency to compute
            let isLinear = engine == .linearPhaseFIR
            filters = isLinear ? preset.filters : []
            curve = isLinear ? preset.curve : []
            baseRate = isLinear ? preset.optimizedSampleRate : 0
        }
    }

    private var latencyText: String {
        guard preset.effectiveEngine == .linearPhaseFIR else { return "None" }
        guard preset.hasCorrection else { return "—" }
        guard let latencyMS else { return "…" }
        return String(format: "%.1f ms", latencyMS)
    }

    /// ±24 dB when the preset does not fit in ±12 dB.
    private static func needsWideScale(_ preset: AutoEQProfile) -> Bool {
        if preset.filters.contains(where: { abs($0.gainDB) > 12 }) || abs(preset.preampDB) > 12 { return true }
        let frequencies = AutoEQResponse.logFrequencies(count: 200)
        return AutoEQResponse.curve(of: preset, frequencies: frequencies)
            .contains { abs($0) > 12 }
    }

    // MARK: - Preset Section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            presetRows
            Text(preset.effectiveEngine.summary)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var presetRows: some View {
        SettingsSection("Preset") {
            row("Name") {
                if isEditing {
                    CommitTextField(value: preset.name, width: 150) { newName in
                        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        editor.apply { $0.name = trimmed }
                    }
                } else {
                    valueText(preset.name)
                }
            }
            Divider()
            row("Type") { valueText(preset.kind.displayName) }
            if let bandCount = preset.bandCount {
                Divider()
                row("Bands") { valueText("\(bandCount) / \(AutoEQProfile.maxFilters)") }
            }
            Divider()
            row("Correction") {
                if isEditing {
                    Picker("Correction", selection: Binding(
                        get: { preset.effectiveEngine },
                        set: { engine in editor.apply { $0.engine = engine } }
                    )) {
                        ForEach(AutoEQCorrectionEngine.available(for: preset.kind)) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 170)
                } else {
                    valueText(preset.effectiveEngine.displayName)
                }
            }
            if preset.kind == .parametric {
                Divider()
                row("Base rate") {
                    if isEditing {
                        Picker("Base rate", selection: Binding(
                            get: { preset.optimizedSampleRate },
                            set: { rate in editor.apply { $0.optimizedSampleRate = rate } }
                        )) {
                            ForEach(baseRateChoices, id: \.self) { Text(AutoEQBaseRate.label($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 170)
                    } else {
                        valueText(AutoEQBaseRate.label(preset.optimizedSampleRate))
                    }
                }
                .help("Sample rate the filters were designed for. AutoEQ uses 44.1 kHz. The exact engines reproduce the curve the filters have at this rate, whatever the rate of the device.")
            }
            Divider()
            row("Latency") { valueText(latencyText) }
            Divider()
            row("Source") { valueText(preset.sourceLabel ?? "AutoEQ") }
        }
    }

    /// The offered rates, plus the preset's own when it is not one of them.
    private var baseRateChoices: [Double] {
        let choices = AutoEQBaseRate.choices
        return choices.contains(preset.optimizedSampleRate) ? choices : [preset.optimizedSampleRate] + choices
    }

    // MARK: - Preamp Section

    private var preampSection: some View {
        let recommended = AutoEQResponse.recommendedPreampDB(preset)
        let peak = AutoEQResponse.peakDB(preset)
        let clipRisk = recommended.map { Double(preset.preampDB) - $0 } ?? 0

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SettingsSection("Preamp") {
                row("Preamp") {
                    if isEditing {
                        DecimalField(
                            value: Double(preset.preampDB),
                            fractionDigits: 1,
                            suffix: "dB"
                        ) { value in
                            let range = AutoEQProfile.preampRange
                            editor.apply { $0.preampDB = min(max(Float(value), range.lowerBound), range.upperBound) }
                        }
                    } else {
                        valueText(String(format: "%+.1f dB", preset.preampDB))
                    }
                }
                Divider()
                row("Recommended") {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        valueText(recommended.map { String(format: "%+.1f dB", $0) } ?? "—")
                        if isEditing, let recommended {
                            Button("Use") {
                                editor.apply { $0.preampDB = Float(recommended) }
                            }
                            .controlSize(.small)
                            .disabled(abs(Double(preset.preampDB) - recommended) < 0.05)
                        }
                    }
                }
                Divider()
                row("Peak boost") { valueText(peak.map { String(format: "%+.1f dB", $0) } ?? "—") }
            }

            if clipRisk > 0.05 {
                Label(String(format: "Can clip by up to %.1f dB", clipRisk), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
            Text("Recommended: peak boost plus \(String(format: "%.1f", AutoEQResponse.recommendedHeadroomDB)) dB of margin, so the corrected sound never exceeds the original level.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Graph Header

    private var graphHeader: some View {
        HStack {
            Text("Frequency Response")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Text(graphCaption)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Spacer()
            Picker("Scale", selection: $scaleDB) {
                Text("±12 dB").tag(12.0)
                Text("±24 dB").tag(24.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 140)
        }
    }

    private var graphCaption: String {
        switch preset.effectiveEngine {
        case .biquad: return "Biquad filters played at 48 kHz"
        case .matchedBiquad: return "Exact biquad filters played at 48 kHz"
        case .minimumPhaseFIR, .linearPhaseFIR:
            guard preset.kind == .parametric else { return "Exact curve" }
            let rate = preset.optimizedSampleRate
            return rate > 0 ? "Exact curve of \(AutoEQBaseRate.label(rate)) filters" : "Exact curve of analog filters"
        }
    }

    // MARK: - Bands Section

    @ViewBuilder
    private var bandsSection: some View {
        switch preset.kind {
        case .parametric:
            VStack(spacing: DesignTokens.Spacing.xs) {
                if isEditing {
                    HStack {
                        Text("Drag a point on the graph to move a band, or type values below.")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                        Spacer()
                        Button {
                            addBand()
                        } label: {
                            Label("Add Band", systemImage: "plus")
                        }
                        .controlSize(.small)
                        .disabled(preset.filters.count >= AutoEQProfile.maxFilters)
                    }
                }
                if preset.filters.isEmpty {
                    placeholder(isEditing ? "No bands yet. Add one above." : "No bands yet. Click Edit to add some.")
                } else {
                    bandTable
                }
            }
        case .graphic:
            if preset.curve.isEmpty {
                placeholder("No curve yet. Import a GraphicEQ file (AutoEQ, Wavelet, Equalizer APO) to fill this preset.")
            } else {
                curveTable
            }
        }
    }

    /// The points of a graphic preset (read-only).
    private var curveTable: some View {
        VStack(spacing: 0) {
            BandRowLayout(isHeader: true) {
                Text("#").bandColumn(0, isHeader: true)
                Text("Frequency").bandColumn(2, isHeader: true)
                Text("Gain").bandColumn(3, isHeader: true)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(preset.curve.enumerated()), id: \.offset) { index, point in
                        BandRowLayout(isHeader: false) {
                            Text("\(index + 1)").bandColumn(0)
                            Text(EQResponseGraph.formatFrequency(point.frequency)).bandColumn(2)
                            Text(String(format: "%+.1f dB", point.gainDB)).bandColumn(3)
                        }
                        .background(index % 2 == 0 ? Color.clear : DesignTokens.Colors.pickerBackground.opacity(0.5))
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private var bandTable: some View {
        VStack(spacing: 0) {
            BandRowLayout(isHeader: true) {
                Text("#").bandColumn(0, isHeader: true)
                Text("Type").bandColumn(1, isHeader: true)
                Text("Frequency").bandColumn(2, isHeader: true)
                Text("Gain").bandColumn(3, isHeader: true)
                Text("Q").bandColumn(4, isHeader: true)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Listed by frequency; `index` stays the band's position in the preset.
                        let order = EQResponseGraph.frequencyOrder(preset.filters)
                        ForEach(Array(order.enumerated()), id: \.element) { rank, index in
                            bandRow(index: index, number: rank + 1, filter: preset.filters[index])
                                .id(index)
                        }
                    }
                }
                .onChange(of: selectedBand) { _, band in
                    guard let band else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(band) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func bandRow(index: Int, number: Int, filter: AutoEQFilter) -> some View {
        let isSelected = index == selectedBand
        BandRowLayout(isHeader: false, isEditing: isEditing) {
            Text("\(number)").bandColumn(0)
            if isEditing {
                Picker("Type", selection: Binding(
                    get: { filter.type },
                    set: { type in updateBand(index) { $0.type = type } }
                )) {
                    Text("Peak").tag(AutoEQFilter.FilterType.peaking)
                    Text("Low shelf").tag(AutoEQFilter.FilterType.lowShelf)
                    Text("High shelf").tag(AutoEQFilter.FilterType.highShelf)
                }
                .labelsHidden()
                .controlSize(.small)
                .bandColumn(1)
                DecimalField(value: filter.frequency, fractionDigits: 0, suffix: "Hz") { value in
                    let range = AutoEQFilter.frequencyRange
                    updateBand(index) { $0.frequency = min(max(value, range.lowerBound), range.upperBound) }
                }
                .bandColumn(2)
                DecimalField(value: Double(filter.gainDB), fractionDigits: 1, suffix: "dB") { value in
                    let range = AutoEQFilter.gainRange
                    updateBand(index) { $0.gainDB = min(max(Float(value), range.lowerBound), range.upperBound) }
                }
                .bandColumn(3)
                DecimalField(value: filter.q, fractionDigits: 2, suffix: nil) { value in
                    let range = AutoEQFilter.qRange
                    updateBand(index) { $0.q = min(max(value, range.lowerBound), range.upperBound) }
                }
                .bandColumn(4)
                Button {
                    removeBand(index)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove band \(number)")
                .bandColumn(5)
            } else {
                Text(EQResponseGraph.typeName(filter.type)).bandColumn(1)
                Text(EQResponseGraph.formatFrequency(filter.frequency)).bandColumn(2)
                Text(String(format: "%+.1f dB", filter.gainDB)).bandColumn(3)
                Text(String(format: "%.2f", filter.q)).bandColumn(4)
            }
        }
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : (number % 2 == 1 ? Color.clear : DesignTokens.Colors.pickerBackground.opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedBand = index }
    }

    // MARK: - Band Edits

    private func updateBand(_ index: Int, _ change: @escaping (inout AutoEQFilter) -> Void) {
        editor.apply { profile in
            guard profile.filters.indices.contains(index) else { return }
            change(&profile.filters[index])
        }
    }

    private func addBand() {
        editor.apply { profile in
            guard profile.filters.count < AutoEQProfile.maxFilters else { return }
            profile.filters.append(AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 0, q: 1))
        }
        selectedBand = preset.filters.count - 1
    }

    private func removeBand(_ index: Int) {
        editor.apply { profile in
            guard profile.filters.indices.contains(index) else { return }
            profile.filters.remove(at: index)
        }
        selectedBand = nil
    }

    // MARK: - Building Blocks

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: DesignTokens.Spacing.sm)
            content()
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: 32)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.autoEQEmptyBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            )
    }
}

// MARK: - Band Row Layout

/// One row of the band table (header or band).
private struct BandRowLayout<Content: View>: View {
    let isHeader: Bool
    var isEditing = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: isHeader ? 26 : (isEditing ? 30 : 24))
    }
}

/// Fixed column widths shared by the header and the band rows.
private struct BandColumn: ViewModifier {
    static let widths: [CGFloat] = [36, 120, 130, 110, 90, 28]

    let index: Int
    let isHeader: Bool

    func body(content: Content) -> some View {
        content
            .font(isHeader ? .system(size: 10, weight: .semibold) : .system(size: 12).monospacedDigit())
            .foregroundStyle(isHeader ? DesignTokens.Colors.textTertiary : DesignTokens.Colors.textPrimary)
            .frame(width: Self.widths[index], alignment: index == 1 ? .leading : .trailing)
            .padding(.trailing, DesignTokens.Spacing.sm)
    }
}

private extension View {
    func bandColumn(_ index: Int, isHeader: Bool = false) -> some View {
        modifier(BandColumn(index: index, isHeader: isHeader))
    }
}

// MARK: - Text Fields

/// Text field that reports its value only when the user presses Return or leaves the field,
/// so typing a word is one undo step, not one per keystroke.
struct CommitTextField: View {
    let value: String
    var width: CGFloat = 120
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: width)
            .focused($isFocused)
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in
                if !isFocused { text = newValue }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit(text) }
            }
            .onSubmit { onCommit(text) }
    }
}

/// Numeric text field with a unit suffix, committed on Return or when leaving the field.
struct DecimalField: View {
    let value: Double
    let fractionDigits: Int
    let suffix: String?
    let onCommit: (Double) -> Void

    var body: some View {
        HStack(spacing: 3) {
            TextField(
                "",
                value: Binding(get: { value }, set: { onCommit($0) }),
                format: .number.precision(.fractionLength(fractionDigits)).grouping(.never)
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
    }
}
