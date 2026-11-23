// FineTune/Views/EQManager/EQManagerConvertSheet.swift
import SwiftUI

/// The conversions of the EQ Manager's Convert menu (see `AutoEQConverter`). Each one makes a
/// new preset; the converted preset is never changed.
enum EQManagerConversionKind: String, Identifiable {
    case toGraphic, toParametric, changeBandCount, changeBaseRate

    var id: String { rawValue }

    /// Conversions offered for a preset of this kind.
    static func available(for kind: AutoEQPresetKind) -> [EQManagerConversionKind] {
        switch kind {
        case .parametric: return [.toGraphic, .changeBandCount, .changeBaseRate]
        case .graphic: return [.toParametric]
        }
    }

    var menuTitle: String {
        switch self {
        case .toGraphic: return "To Graphic EQ..."
        case .toParametric: return "To Parametric EQ..."
        case .changeBandCount: return "With Another Number of Bands..."
        case .changeBaseRate: return "To Another Base Rate..."
        }
    }

    var title: String {
        switch self {
        case .toGraphic: return "Convert to Graphic EQ"
        case .toParametric: return "Convert to Parametric EQ"
        case .changeBandCount: return "Fit Another Number of Bands"
        case .changeBaseRate: return "Move to Another Base Rate"
        }
    }

    var explanation: String {
        switch self {
        case .toGraphic:
            return "The curve of the preset, sampled from 20 Hz to 20 kHz: for apps that read a GraphicEQ.txt (Wavelet, Equalizer APO)."
        case .toParametric:
            return "Bands fitted to the curve, to edit it as bands or to play it with the biquad engines."
        case .changeBandCount:
            return "New bands fitted to the curve of the preset."
        case .changeBaseRate:
            return "The same bands, moved so that they give the same curve at another base rate: for an app that plays them at that rate, or as analog filters."
        }
    }
}

/// What the Convert sheet is open for.
struct EQManagerConversionRequest: Identifiable {
    let id = UUID()
    let kind: EQManagerConversionKind
    let source: AutoEQProfile
}

/// A conversion running off the main thread, with its progress and result.
@Observable
@MainActor
final class EQManagerConversionRun {
    private(set) var isRunning = false
    private(set) var progress = 0.0
    private(set) var result: AutoEQConverter.Conversion?
    private(set) var failure: String?
    private var task: Task<AutoEQConverter.Conversion, Error>?

    /// Run `work` in the background; it reports its progress through the closure it is given.
    func start(
        _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) throws -> AutoEQConverter.Conversion
    ) {
        cancel()
        isRunning = true
        let reporter: @Sendable (Double) -> Void = { value in
            Task { @MainActor in self.progress = value }
        }
        let task = Task.detached(priority: .userInitiated) { try work(reporter) }
        self.task = task
        Task {
            let outcome = await task.result
            // Cancelled or replaced meanwhile
            guard self.task == task else { return }
            self.task = nil
            self.isRunning = false
            switch outcome {
            case .success(let conversion):
                self.result = conversion
            case .failure(let error):
                if !(error is CancellationError) { self.failure = "The conversion failed." }
            }
        }
    }

    /// Show a result computed on the spot.
    func show(_ conversion: AutoEQConverter.Conversion) {
        cancel()
        result = conversion
    }

    /// Stop the running conversion and forget the last result.
    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        progress = 0
        result = nil
        failure = nil
    }
}

/// Options of a conversion, its result (how close it is to the original) and the name of the
/// new preset.
@MainActor
struct EQManagerConvertSheet: View {
    let request: EQManagerConversionRequest
    let onCreate: (_ profile: AutoEQProfile, _ name: String) -> Void
    let onCancel: () -> Void

    @State private var run = EQManagerConversionRun()
    @State private var pointCount = 127
    @State private var bandCount = 10
    @State private var usesTolerance = false
    @State private var toleranceDB = 0.1
    @State private var maxQ = 10.0
    @State private var allowsShelves = true
    @State private var baseRate = AutoEQBaseRate.autoEQDefault
    @State private var name = ""
    @State private var isNameEdited = false

    private var source: AutoEQProfile { request.source }
    private var kind: EQManagerConversionKind { request.kind }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Everything the result depends on.
    private struct Settings: Equatable {
        var pointCount: Int
        var bandCount: Int
        var usesTolerance: Bool
        var toleranceDB: Double
        var maxQ: Double
        var allowsShelves: Bool
        var baseRate: Double
    }

    private var settings: Settings {
        Settings(
            pointCount: pointCount, bandCount: bandCount, usesTolerance: usesTolerance, toleranceDB: toleranceDB,
            maxQ: maxQ, allowsShelves: allowsShelves, baseRate: baseRate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text(kind.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text("\(kind.explanation) “\(source.name)” is not changed: the result is a new preset.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            options

            resultLine

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                TextField("Preset name", text: Binding(
                    get: { name },
                    set: { name = $0; isNameEdited = true }
                ))
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    run.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                if let result = run.result {
                    Button("Create Preset") { onCreate(result.profile, trimmedName) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty)
                } else {
                    Button("Convert", action: convert)
                        .keyboardShortcut(.defaultAction)
                        .disabled(run.isRunning)
                }
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 460)
        .onAppear(perform: setUp)
        .onDisappear { run.cancel() }
        .onChange(of: settings) { _, _ in settingsChanged() }
    }

    // MARK: - Options

    @ViewBuilder
    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.md, verticalSpacing: DesignTokens.Spacing.sm) {
            switch kind {
            case .toGraphic:
                GridRow {
                    optionLabel("Points")
                    Picker("Points", selection: $pointCount) {
                        ForEach(AutoEQConverter.graphicPointCounts, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
            case .toParametric, .changeBandCount:
                GridRow {
                    optionLabel(usesTolerance ? "Most bands" : "Bands")
                    Stepper(value: $bandCount, in: 1...AutoEQConverter.maxBandCount) {
                        Text("\(bandCount)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                    }
                }
                GridRow {
                    optionLabel("Fewer bands")
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Toggle("When within", isOn: $usesTolerance)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                        Picker("Tolerance", selection: $toleranceDB) {
                            ForEach(AutoEQConverter.toleranceChoices, id: \.self) {
                                Text(String(format: "%g dB", $0)).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 90)
                        .disabled(!usesTolerance)
                    }
                    .help("Use the fewest bands, up to the number above, whose curve stays this close to the original")
                }
                GridRow {
                    optionLabel("Max Q")
                    Picker("Max Q", selection: $maxQ) {
                        ForEach(AutoEQConverter.maxQChoices, id: \.self) { Text(String(format: "%g", $0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 90)
                    .help("Narrow bands follow sharp details more closely but ring longer")
                }
                GridRow {
                    optionLabel("Shelves")
                    Toggle("Low and high shelf bands", isOn: $allowsShelves)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                GridRow {
                    optionLabel("Base rate")
                    baseRatePicker(rateChoices)
                        .help("Sample rate the new filters are designed for. AutoEQ uses 44.1 kHz.")
                }
            case .changeBaseRate:
                GridRow {
                    optionLabel("From")
                    Text(AutoEQBaseRate.label(source.optimizedSampleRate))
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                }
                GridRow {
                    optionLabel("To")
                    baseRatePicker(AutoEQBaseRate.choices.filter { $0 != source.optimizedSampleRate })
                }
            }
        }
    }

    private func optionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .gridColumnAlignment(.trailing)
    }

    /// The usual base rates, and the source's when it is another one.
    private var rateChoices: [Double] {
        let choices = AutoEQBaseRate.choices
        let current = source.optimizedSampleRate
        return source.kind != .parametric || choices.contains(current) ? choices : choices + [current]
    }

    private func baseRatePicker(_ choices: [Double]) -> some View {
        Picker("Base rate", selection: $baseRate) {
            ForEach(choices, id: \.self) { Text(AutoEQBaseRate.label($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 140)
    }

    // MARK: - Result

    private var resultLine: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if run.isRunning {
                ProgressView(value: run.progress)
                    .frame(width: 160)
                Text("Fitting bands...")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else if let result = run.result {
                Text(resultText(result))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = run.failure {
                Text(failure)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else {
                Text("Convert to see how close the result is to the original.")
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .font(.system(size: 11))
        .frame(minHeight: 30, alignment: .leading)
    }

    private func resultText(_ conversion: AutoEQConverter.Conversion) -> String {
        let error = conversion.accuracy.maxErrorDB
        let difference: String
        if error < 0.001 {
            difference = "less than 0.001 dB"
        } else {
            let value = String(format: error < 0.1 ? "%.3f dB" : "%.2f dB", error)
            difference = "\(value) at \(EQResponseGraph.formatFrequency(conversion.accuracy.frequency))"
        }
        return "\(conversion.profile.attributesSummary). Largest difference from the original: \(difference)."
    }

    // MARK: - Actions

    private var suggestedName: String {
        switch kind {
        case .toGraphic:
            return "\(source.name) (Graphic)"
        // No band count: the result may have another number of bands than the one asked for
        case .toParametric:
            return "\(source.name) (Parametric)"
        case .changeBandCount:
            return "\(source.name) (Refitted)"
        case .changeBaseRate:
            return "\(source.name) (\(AutoEQBaseRate.label(baseRate)))"
        }
    }

    private func setUp() {
        switch kind {
        case .toGraphic:
            run.show(AutoEQConverter.graphic(from: source, pointCount: pointCount))
        case .toParametric:
            baseRate = AutoEQBaseRate.lastImportRate
        case .changeBandCount:
            bandCount = min(max(source.filters.count, 1), AutoEQConverter.maxBandCount)
            baseRate = source.optimizedSampleRate
        case .changeBaseRate:
            baseRate = source.optimizedSampleRate == 48_000 ? 44_100 : 48_000
        }
        name = suggestedName
    }

    /// A setting changed: the last result no longer applies (a graphic conversion is redone at once).
    private func settingsChanged() {
        if kind == .toGraphic {
            run.show(AutoEQConverter.graphic(from: source, pointCount: pointCount))
        } else {
            run.cancel()
        }
        if !isNameEdited { name = suggestedName }
    }

    private func convert() {
        let source = self.source
        switch kind {
        case .toGraphic:
            run.show(AutoEQConverter.graphic(from: source, pointCount: pointCount))
        case .toParametric, .changeBandCount:
            let options = AutoEQConverter.ParametricOptions(
                bandCount: bandCount, toleranceDB: usesTolerance ? toleranceDB : nil, maxQ: maxQ,
                allowsShelves: allowsShelves, baseRate: baseRate)
            run.start { progress in
                try AutoEQConverter.parametric(from: source, options: options, progress: progress)
            }
        case .changeBaseRate:
            let rate = baseRate
            run.start { progress in
                try AutoEQConverter.rebased(source, to: rate, progress: progress)
            }
        }
    }
}
