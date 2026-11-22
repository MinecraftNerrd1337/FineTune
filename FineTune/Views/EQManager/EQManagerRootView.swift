// FineTune/Views/EQManager/EQManagerRootView.swift
import SwiftUI
import UniformTypeIdentifiers

/// Content of the "FineTune EQ Manager" window: a preset selector and edit controls on top,
/// the selected preset (response graph, preamp, bands) below.
///
/// Saving follows the library's rules (`AutoEQProfileManager.saveKind`): a preset is saved in
/// place, after a confirmation (a setting) and with its replaced version kept in its history; a
/// template keeps its bands, so changing them saves a new preset. The Convert menu makes a new
/// preset from the one shown, in another form (`EQManagerConvertSheet`). The Apply to DAC menu
/// makes an output device use the preset shown (`EQManagerApplyButton`). The devices that use
/// the preset shown can play it as saved, with its edits, or another preset it is compared
/// with, at the same perceived level (`EQManagerComparison`).
@MainActor
struct EQManagerRootView: View {
    static let title = "FineTune EQ Manager"
    /// Width of a preset's name in the compare bar.
    private static let chipNameWidth: CGFloat = 130
    /// Opening and minimum size: same height as the Settings window, 1.4x its width (720).
    /// The window can grow from there; the graph and the band table share the extra height.
    static let size = CGSize(width: 1008, height: 560)

    @Bindable var settings: SettingsManager
    let audioEngine: AudioEngine
    @Bindable var comparison: EQManagerComparison

    /// What the preset chooser sheet is open for.
    private enum ChooserPurpose: String, Identifiable {
        case select, replace, compare
        var id: String { rawValue }
    }

    @State private var editor: EQManagerEditor?
    @State private var chooserPurpose: ChooserPurpose?
    /// A filter list picked in the chooser: its base rate sheet opens once the chooser is gone.
    @State private var importAfterChooser: EQManagerImportRequest?
    @State private var importRequest: EQManagerImportRequest?
    @State private var isReplaceImporterPresented = false
    @State private var alertMessage: String?
    @State private var isSaveConfirmationPresented = false
    @State private var newPresetRequest: EQManagerNewPresetRequest?
    @State private var isClearHistoryConfirmationPresented = false
    @State private var conversionRequest: EQManagerConversionRequest?

    private var profileManager: AutoEQProfileManager { audioEngine.autoEQProfileManager }

    var body: some View {
        // Split up so the compiler type-checks the body in reasonable time
        withPresetSheets(layout)
        .sheet(item: $newPresetRequest) { request in
            EQManagerNewPresetSheet(
                request: request,
                onCreate: { name, useOnDevices in
                    newPresetRequest = nil
                    createPreset(named: name, useOnDevices: useOnDevices)
                },
                onCancel: { newPresetRequest = nil }
            )
            .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        }
        .sheet(item: $conversionRequest) { request in
            EQManagerConvertSheet(
                request: request,
                onCreate: { profile, name in
                    conversionRequest = nil
                    createConvertedPreset(profile, named: name)
                },
                onCancel: { conversionRequest = nil }
            )
            .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        }
        .fileImporter(isPresented: $isReplaceImporterPresented, allowedContentTypes: [.plainText]) { result in
            if case .success(let url) = result { replaceContents(withFileAt: url) }
        }
        .alert(
            alertMessage ?? "",
            isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog(
            clearHistoryTitle,
            isPresented: $isClearHistoryConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Versions", role: .destructive) {
                if let id = activeEditor?.draft.id { profileManager.history.clear(profileID: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The preset itself is not changed. This cannot be undone.")
        }
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
        // The devices that use the preset follow every edit, or the saved preset
        .onChange(of: comparisonProfiles, initial: true) { _, profiles in
            comparison.update(profiles, engine: audioEngine)
        }
        // Another preset shown: the level is matched again
        .onChange(of: editor?.original.id) { _, _ in
            comparison.manualTrimDB = nil
        }
    }

    // MARK: - Comparison

    /// The connected devices whose AutoEQ preset is the one shown.
    private var devicesUsingPreset: [AudioDevice] {
        guard let id = editor?.original.id else { return [] }
        return audioEngine.outputDevices.filter { settings.getAutoEQSelection(for: $0.uid)?.profileID == id }
    }

    /// The preset compared with the one shown, as saved: as the library holds it now. Nil when
    /// it is the preset shown.
    private var comparedSavedPreset: AutoEQProfile? {
        guard let other = comparison.comparedEditor, other.original.id != editor?.original.id else { return nil }
        return profileManager.profile(for: other.original.id) ?? other.original
    }

    /// The compared preset as worked on: with its edits while it is edited.
    private var comparedPreset: AutoEQProfile? {
        guard let saved = comparedSavedPreset, let other = comparison.comparedEditor else { return nil }
        return other.isEditing ? other.draft : saved
    }

    private var hearableVersions: [EQManagerComparison.Version] {
        EQManagerComparison.versions(
            isEditing: editor?.isEditing == true,
            isComparing: comparedSavedPreset != nil,
            comparedIsEditing: comparison.comparedIsEditing
        )
    }

    /// The version of the compared preset whose level is shown and drawn: the one heard, or
    /// the one worked on while the preset shown is heard.
    private var comparedFocus: AutoEQProfile? {
        switch comparison.current(in: hearableVersions) {
        case .compared: comparedSavedPreset
        default: comparedPreset
        }
    }

    /// Whether a device's correction is on (on when it has no AutoEQ selection).
    private func isCorrectionOn(_ deviceUID: String) -> Bool {
        settings.getAutoEQSelection(for: deviceUID)?.isEnabled ?? true
    }

    /// The extra gain of a version of the compared preset, on a device whose correction is on or
    /// off: set by hand, or matching its level to the preset shown (with its edits) as that
    /// device plays them, with the Preamp switch as it is now.
    private func comparedTrimDB(_ compared: AutoEQProfile, correctionOn: Bool) -> Double {
        if let manual = comparison.manualTrimDB { return manual }
        guard let editor else { return 0 }
        return EQManagerComparison.matchingTrimDB(
            reference: audioEngine.activeAutoEQProfile(editor.draft, correctionEnabled: correctionOn),
            compared: audioEngine.activeAutoEQProfile(compared, correctionEnabled: correctionOn),
            preampOn: audioEngine.autoEQPreampEnabled
        )
    }

    /// What those devices play instead of their own AutoEQ, each following its Correction switch:
    /// the edits, or a version of the compared preset with its extra gain. Nothing for the
    /// saved preset.
    private var comparisonProfiles: [String: AutoEQProfile] {
        guard let editor else { return [:] }
        let version = comparison.current(in: hearableVersions)
        let compared: AutoEQProfile?
        switch version {
        case .saved: return [:]
        case .edited: compared = nil
        case .compared: compared = comparedSavedPreset
        case .comparedEdited: compared = comparison.comparedEditor?.draft
        }
        var profiles: [String: AutoEQProfile] = [:]
        for device in devicesUsingPreset {
            let correctionOn = isCorrectionOn(device.uid)
            if let compared {
                var profile = audioEngine.activeAutoEQProfile(compared, correctionEnabled: correctionOn)
                profile.comparisonGainDB = Float(comparedTrimDB(compared, correctionOn: correctionOn))
                profiles[device.uid] = profile
            } else if version == .edited {
                profiles[device.uid] = audioEngine.activeAutoEQProfile(editor.draft, correctionEnabled: correctionOn)
            }
        }
        return profiles
    }

    private func versionTitle(_ version: EQManagerComparison.Version, isEditing: Bool) -> String {
        switch version {
        case .saved: isEditing ? "Saved" : "This Preset"
        case .edited: "Edited"
        case .compared: comparison.comparedIsEditing ? "Compared · Saved" : "Compared"
        case .comparedEdited: "Compared · Edited"
        }
    }

    /// The versions to hear on the devices that use the preset, and ⌘B to go back to the one
    /// heard before.
    @ViewBuilder
    private var hearControl: some View {
        let devices = devicesUsingPreset
        let versions = hearableVersions
        let isEditing = editor?.isEditing == true
        if devices.isEmpty {
            Text("Apply this preset to a device to hear it")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize()
        } else if versions.count > 1 {
            let names = devices.map(\.name).joined(separator: ", ")
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Hear")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize()
                // Drawn here rather than with a segmented Picker, whose segments keep stale widths
                // when their number or titles change
                EQManagerHearSegments(
                    versions: versions,
                    selection: comparison.current(in: versions),
                    title: { versionTitle($0, isEditing: isEditing) },
                    onSelect: { comparison.select($0, in: versions) }
                )
                Button {
                    comparison.toggle(in: versions)
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .frame(width: 18)
                }
                .keyboardShortcut("b", modifiers: .command)
                .help("Go back to the version heard before (⌘B)")
            }
            // Never shrunk: the preset names give way instead
            .fixedSize()
            .layoutPriority(1)
            .help("What \(names) play\(devices.count == 1 ? "s" : ""). Nothing is stored until you save.")
        }
    }

    /// While comparing, a bar under the top bar: which preset the window shows and edits, and
    /// what the devices play. The level of the compared preset is set in the Preamp section.
    @ViewBuilder
    private var compareBar: some View {
        if let editor, let compared = comparedPreset {
            let hasChanges = comparison.comparedHasChanges
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("Show")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize()
                presetChip(editor.draft, side: .base, editor: editor)
                presetChip(compared, side: .compared, editor: comparison.comparedEditor)
                // Hear starts at the same place whatever its segments: it only grows to the right
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                hearControl
                Spacer(minLength: DesignTokens.Spacing.sm)
                Button {
                    comparison.stopComparing()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 14)
                }
                .disabled(hasChanges)
                .help(hasChanges
                      ? "“\(compared.name)” has unsaved changes: save or discard them to stop comparing"
                      : "Stop comparing")
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.sm)
            Divider()
        }
    }

    /// One of the compared presets, in the color of its curve: choosing it shows it in the window,
    /// to see or edit it. Its pencil edits it; filled, it marks the preset being edited in the
    /// window, outlined, a preset in edit mode that is not shown.
    private func presetChip(_ preset: AutoEQProfile, side: EQManagerComparison.Side, editor: EQManagerEditor?) -> some View {
        let isShown = comparison.displayed == side
        let isEditing = editor?.isEditing == true
        let color = side == .base ? EQResponseGraph.baseCurveColor : EQResponseGraph.comparedCurveColor
        let state = editor.flatMap { editState($0) }
        return HStack(spacing: 4) {
            Button {
                showSide(side)
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    // The same width whatever the name, its weight or the Edited mark, so the
                    // bar never moves
                    HStack(spacing: 4) {
                        Text(preset.name)
                            .font(.system(size: 11, weight: isShown ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let state {
                            Text(state)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(color)
                                .fixedSize()
                        }
                    }
                    .frame(width: Self.chipNameWidth, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(side == .base
                  ? "Show the preset of the top bar, to see or edit it"
                  : "Show the compared preset, to see or edit it")

            Button {
                edit(side)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isEditing && isShown ? Color.white : isEditing ? color : DesignTokens.Colors.textTertiary)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(isEditing && isShown ? color : Color.clear))
                    .overlay(Circle().strokeBorder(isEditing && !isShown ? color : Color.clear, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(pencilHelp(preset, isEditing: isEditing, isShown: isShown))
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(isShown ? 0.2 : 0.06)))
        .overlay(Capsule().strokeBorder(color.opacity(isShown ? 0.7 : 0.25), lineWidth: 1))
    }

    private func pencilHelp(_ preset: AutoEQProfile, isEditing: Bool, isShown: Bool) -> String {
        if isEditing && isShown { return "Editing “\(preset.name)”" }
        if isEditing { return "“\(preset.name)” is in edit mode: show it to edit it" }
        return "Edit “\(preset.name)” and show it. The other preset is left as it is."
    }

    /// Edits one of the compared presets alone, and shows it.
    private func edit(_ side: EQManagerComparison.Side) {
        switch side {
        case .base:
            guard let editor else { return }
            if !editor.isEditing {
                editor.beginEditing()
                comparison.beginEditing(.base)
            }
            comparison.displayed = .base
        case .compared:
            editCompared()
        }
    }

    /// Unsaved changes; edit mode itself shows on the pencil.
    private func editState(_ editor: EQManagerEditor) -> String? {
        editor.hasChanges ? "Edited" : nil
    }

    /// Shows one of the compared presets. The compared one, when not edited, is shown as the
    /// library holds it now.
    private func showSide(_ side: EQManagerComparison.Side) {
        if side == .compared { refreshComparedEditor() }
        comparison.displayed = side
    }

    /// Edits the compared preset, and shows it. The preset of the top bar is left as it is.
    private func editCompared() {
        refreshComparedEditor()
        guard let other = comparison.comparedEditor else { return }
        if !other.isEditing {
            other.beginEditing()
            comparison.beginEditing(.compared)
        }
        comparison.displayed = .compared
    }

    /// The compared preset, not edited, holds the library's version, which may be newer than the
    /// one chosen.
    private func refreshComparedEditor() {
        guard let other = comparison.comparedEditor, !other.isEditing,
              let current = profileManager.profile(for: other.original.id), current != other.original else { return }
        comparison.replaceCompared(with: EQManagerEditor(profile: current))
    }

    /// The editor of the preset the window shows: the compared one when chosen in the compare
    /// bar, otherwise the preset of the top bar. The edit bar and the content act on it.
    private var activeEditor: EQManagerEditor? {
        if comparison.displayed == .compared, comparedSavedPreset != nil, let other = comparison.comparedEditor {
            return other
        }
        return editor
    }

    private var isShowingCompared: Bool {
        guard let active = activeEditor, let editor else { return false }
        return active !== editor
    }

    /// The comparison as the Preset Detail shows it, from the preset it shows: the other preset's
    /// curve on the graph, at the level it plays at against this one (preamps and the extra
    /// gain), and the extra gain of the compared preset in the Preamp section, as the first
    /// device that uses the preset plays it.
    private var detailComparison: EQManagerPresetDetail.Comparison? {
        guard let editor, let compared = comparedFocus else { return nil }
        let correctionOn = devicesUsingPreset.first.map { isCorrectionOn($0.uid) } ?? true
        let trim = comparedTrimDB(compared, correctionOn: correctionOn)
        let preampOn = audioEngine.autoEQPreampEnabled
        let range = EQManagerComparison.trimRange
        // How much higher the compared preset plays than the preset of the top bar
        let comparedOffset = (preampOn ? Double(compared.preampDB) - Double(editor.draft.preampDB) : 0) + trim
        let showsCompared = isShowingCompared
        return EQManagerPresetDetail.Comparison(
            other: showsCompared ? editor.draft : compared,
            otherOffsetDB: showsCompared ? -comparedOffset : comparedOffset,
            otherColor: showsCompared ? EQResponseGraph.baseCurveColor : EQResponseGraph.comparedCurveColor,
            comparedPreampDB: compared.preampDB,
            trimDB: trim,
            isMatched: comparison.manualTrimDB == nil,
            preampOn: preampOn,
            setTrim: { [comparison] value in
                comparison.manualTrimDB = min(max((value * 10).rounded() / 10, range.lowerBound), range.upperBound)
            },
            match: { [comparison] in comparison.manualTrimDB = nil }
        )
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            EQManagerPresetSelectorButton(preset: editor?.draft) {
                chooserPurpose = .select
            }
            .disabled(editor?.isEditing == true)
            .help(editor?.isEditing == true ? "Save or discard your changes to choose another preset" : "")

            if let editor {
                EQManagerFavoriteButton(
                    isFavorite: settings.isAutoEQFavorite(id: editor.draft.id),
                    onToggle: { toggleFavorite(editor.draft.id) }
                )
            }

            Spacer()

            if let editor {
                Button {
                    chooserPurpose = .compare
                } label: {
                    // While comparing, it changes the compared preset
                    Label(comparedPreset == nil ? "Compare" : "Change", systemImage: "square.split.2x1")
                }
                .disabled(comparison.comparedHasChanges)
                .help(compareHelp)
                EQManagerApplyButton(
                    audioEngine: audioEngine,
                    preset: editor.original,
                    hasChanges: editor.hasChanges
                )
                convertMenu(editor)
                // Stays in place in edit mode, so the menus beside it don't move: the edit
                // controls have a bar of their own (`editBar`)
                Button {
                    editor.beginEditing()
                    comparison.beginEditing(.base)
                    comparison.displayed = .base
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(editor.isEditing)
                .help(editHelp(editor))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        // Only this dialog offers "Do not ask again" (the toggle applies to dialogs shown from here)
        .confirmationDialog(
            "Save changes to “\(activeEditor?.original.name ?? "")”?",
            isPresented: $isSaveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Save") { if let editor = activeEditor { saveInPlace(editor) } }
            Button("Save as New Preset...") { if let editor = activeEditor { requestNewPreset(from: editor) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(saveConfirmationMessage)
        }
        .dialogSuppressionToggle(isSuppressed: Binding(
            get: { !settings.appSettings.confirmPresetSaves },
            set: { settings.appSettings.confirmPresetSaves = !$0 }
        ))
    }

    private var compareHelp: String {
        if comparison.comparedHasChanges {
            return "The compared preset has unsaved changes: show it with the arrows to save or discard them"
        }
        return comparedPreset == nil
            ? "Compare this preset with another one, by ear and on the graph. Your edits are kept."
            : "Compare with another preset instead of the compared one"
    }

    private func editHelp(_ editor: EQManagerEditor) -> String {
        if editor.isEditing { return "Editing: save, discard or leave edit mode in the bar below" }
        return editor.draft.isTemplate
            ? "Templates keep their bands: changing them saves a new preset"
            : "Make this preset editable"
    }

    /// The edit controls, in a bar under the top bar while the preset shown is edited.
    @ViewBuilder
    private var editBar: some View {
        if let editor = activeEditor, editor.isEditing {
            HStack(spacing: DesignTokens.Spacing.sm) {
                // While comparing, which of the two presets is edited
                if comparedPreset != nil {
                    editedPresetLabel(editor)
                }
                editControls(editor)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.sm)
            Divider()
        }
    }

    private func editedPresetLabel(_ editor: EQManagerEditor) -> some View {
        let color = isShowingCompared ? EQResponseGraph.comparedCurveColor : EQResponseGraph.baseCurveColor
        return HStack(spacing: 5) {
            Image(systemName: "pencil")
                .foregroundStyle(color)
            Text(editor.original.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
        }
        .help(isShowingCompared ? "Editing the compared preset" : "Editing the preset of the top bar")
    }

    /// Undo, redo, Replace and History on the left, what to hear in the middle (in the compare
    /// bar while comparing), leaving edit mode and saving on the right.
    @ViewBuilder
    private func editControls(_ editor: EQManagerEditor) -> some View {
        let saveKind = AutoEQProfileManager.saveKind(original: editor.original, draft: editor.draft)

        HStack(spacing: 2) {
            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 18)
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!editor.canUndo)
            .help("Undo")

            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 18)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!editor.canRedo)
            .help("Redo")
        }

        Menu("Replace") {
            Button("With a ParametricEQ.txt File...") { isReplaceImporterPresented = true }
            Button("With Another Preset...") { chooserPurpose = .replace }
            if let templateID = editor.draft.templateID {
                Button("With Its Template") { replaceContents(withTemplate: templateID) }
            }
        }
        .fixedSize()
        .help("Replace the bands and preamp of this preset (name and settings are kept)")

        historyMenu(editor)

        // In the middle of the bar, or in the compare bar while comparing
        Spacer()
        if comparedPreset == nil, !devicesUsingPreset.isEmpty {
            hearControl
            Spacer()
        }

        Button(editor.hasChanges ? "Discard" : "Done") {
            editor.discard()
        }
        .help(editor.hasChanges ? "Drop all unsaved changes" : "Leave edit mode")

        if saveKind == .updateInPlace {
            Button("Save as New...") {
                NSApp.keyWindow?.makeFirstResponder(nil)
                requestNewPreset(from: editor)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help(editor.original.isTemplate
                  ? "Create a preset from this template, with your changes"
                  : "Save the changes as a new preset and leave this one as it is")
        }

        // Making a preset needs no change: it can start as a copy of the template
        Button(saveKind == .createPreset ? "Save as Preset..." : "Save") {
            save(editor)
        }
        .keyboardShortcut("s", modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(saveKind == .updateInPlace && !editor.hasChanges)
        .help(saveHelp(editor, saveKind))
    }

    private func saveHelp(_ editor: EQManagerEditor, _ kind: AutoEQSaveKind) -> String {
        switch kind {
        case .createPreset where editor.original.source.isLocal:
            return "Templates keep their bands as imported: the changes are saved as a new preset"
        case .createPreset:
            return "Catalog presets stay untouched: the changes are saved as a new preset"
        case .updateInPlace where editor.original.isTemplate:
            return "Save the name, base rate and correction of this template (its bands do not change)"
        case .updateInPlace:
            return settings.appSettings.presetHistoryLimit > 0
                ? "Save the changes to this preset (the current version goes to its history)"
                : "Save the changes to this preset (version history is off in Settings)"
        }
    }

    /// The preset chooser, to show a preset or to replace the bands of the one shown.
    private func presetChooser(_ purpose: ChooserPurpose) -> EQManagerPresetChooser {
        let selects = purpose == .select
        let onDelete: ((String) -> Void)? = selects ? { deletePreset($0) } : nil
        // The chooser opens outside edit mode only: nothing unsaved is lost
        let onDeselect: (() -> Void)? = selects ? { showNoPreset() } : nil
        return EQManagerPresetChooser(
            settings: settings,
            profileManager: profileManager,
            selectedPresetID: chooserSelection(purpose),
            title: chooserTitle(purpose),
            allowsCreation: selects,
            onChoose: { profile in
                chooserPurpose = nil
                switch purpose {
                case .select: show(profile)
                case .replace: replaceContents(with: profile)
                case .compare: compare(with: profile)
                }
            },
            onDeselect: onDeselect,
            onImportFilterList: { request in
                importAfterChooser = request
                chooserPurpose = nil
            },
            onDelete: onDelete,
            onCancel: { chooserPurpose = nil }
        )
    }

    private func chooserSelection(_ purpose: ChooserPurpose) -> String? {
        switch purpose {
        case .select: editor?.draft.id
        case .replace: nil
        case .compare: comparedPreset?.id
        }
    }

    private func chooserTitle(_ purpose: ChooserPurpose) -> String {
        switch purpose {
        case .select: "Choose a Preset"
        case .replace: "Replace Bands With a Preset"
        case .compare: "Compare With a Preset"
        }
    }

    /// Shows `profile` in the top bar. When it is the compared preset, it moves there with its
    /// edits, and the comparison ends.
    private func show(_ profile: AutoEQProfile) {
        if let other = comparison.comparedEditor, other.original.id == profile.id {
            editor = other.isEditing ? other : EQManagerEditor(profile: profile)
            comparison.stopComparing()
        } else {
            editor = EQManagerEditor(profile: profile)
        }
    }

    /// Compares the preset shown with `profile`, still hearing the preset shown. Choosing the
    /// preset shown changes nothing.
    private func compare(with profile: AutoEQProfile) {
        guard let editor, profile.id != editor.original.id else { return }
        comparison.compare(with: profile, isEditing: editor.isEditing)
    }

    /// Deletes a preset or template of the library (confirmed in the chooser): the devices that
    /// use it are left with no AutoEQ preset, and the window shows none if it showed it.
    private func deletePreset(_ id: String) {
        for uid in settings.deviceUIDs(usingAutoEQProfile: id) {
            audioEngine.setAutoEQProfile(for: uid, profileID: nil)
        }
        settings.unfavoriteAutoEQProfile(id: id)
        profileManager.history.clear(profileID: id)
        profileManager.deleteImportedProfile(id: id)
        if editor?.original.id == id { editor = nil }
        if comparison.comparedEditor?.original.id == id { comparison.stopComparing() }
    }

    // MARK: - Import

    private var layout: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            compareBar
            editBar
            content
        }
        .frame(minWidth: Self.size.width, maxWidth: .infinity, minHeight: Self.size.height, maxHeight: .infinity)
    }

    /// The preset chooser, and the import sheet that takes its place for a filter list.
    private func withPresetSheets(_ view: some View) -> some View {
        view
            .sheet(item: $chooserPurpose, onDismiss: presentPendingImport) { purpose in
                presetChooser(purpose)
                    .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
            }
            .sheet(item: $importRequest) { request in
                importSheet(request)
                    .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
            }
    }

    /// A sheet replaces another only once the first is gone.
    private func presentPendingImport() {
        guard let request = importAfterChooser else { return }
        importAfterChooser = nil
        importRequest = request
    }

    private func importSheet(_ request: EQManagerImportRequest) -> EQManagerImportSheet {
        EQManagerImportSheet(
            request: request,
            onImport: { baseRate in
                importRequest = nil
                importFilterList(request, baseRate: baseRate)
            },
            onCancel: { importRequest = nil }
        )
    }

    private func importFilterList(_ request: EQManagerImportRequest, baseRate: Double) {
        let didAccess = request.url.startAccessingSecurityScopedResource()
        defer { if didAccess { request.url.stopAccessingSecurityScopedResource() } }
        guard let profile = profileManager.importProfile(from: request.url, name: request.name, baseRate: baseRate) else {
            alertMessage = "Could not read \(request.url.lastPathComponent). Check the file format."
            return
        }
        AutoEQBaseRate.lastImportRate = baseRate
        editor = EQManagerEditor(profile: profile)
    }

    private func showNoPreset() {
        chooserPurpose = nil
        editor = nil
    }

    // MARK: - Convert

    /// New presets made from this one in another form. Disabled in edit mode: a conversion
    /// starts from the stored preset.
    private func convertMenu(_ editor: EQManagerEditor) -> some View {
        let preset = editor.original
        return Menu {
            ForEach(EQManagerConversionKind.available(for: preset.kind)) { kind in
                Button(kind.menuTitle) {
                    conversionRequest = EQManagerConversionRequest(kind: kind, source: preset)
                }
            }
        } label: {
            Label("Convert", systemImage: "arrow.triangle.2.circlepath")
        }
        .fixedSize()
        .disabled(editor.isEditing || !preset.hasCorrection)
        .help(convertHelp(editor))
    }

    private func convertHelp(_ editor: EQManagerEditor) -> String {
        if editor.isEditing { return "Leave edit mode to convert this preset: a conversion starts from the saved preset" }
        return editor.original.hasCorrection
            ? "Make a new preset from this one in another form. This preset is not changed."
            : "This preset has no bands or curve to convert"
    }

    // MARK: - History

    @ViewBuilder
    private func historyMenu(_ editor: EQManagerEditor) -> some View {
        let versions = profileManager.history.versions(of: editor.original.id)
        if !versions.isEmpty {
            Menu {
                Section("Restore an Earlier Version") {
                    ForEach(versions) { version in
                        Button(versionLabel(version, current: editor.original)) { restore(version) }
                    }
                }
                Divider()
                Button("Delete Earlier Versions...") { isClearHistoryConfirmationPresented = true }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .fixedSize()
            .help("Earlier versions of this preset. Restoring one replaces the bands, preamp and settings in your edits (it can be undone): the saved version changes only when you save.")
        }
    }

    private func versionLabel(_ version: AutoEQPresetVersion, current: AutoEQProfile) -> String {
        let date = version.replacedAt.formatted(date: .abbreviated, time: .shortened)
        let name = version.profile.name == current.name ? "" : "“\(version.profile.name)” · "
        return "\(date) · \(name)\(version.profile.attributesSummary)"
    }

    /// Load an earlier version into the draft (one undo step). Nothing is stored until saved.
    private func restore(_ version: AutoEQPresetVersion) {
        guard let editor = activeEditor else { return }
        if !editor.isEditing {
            editor.beginEditing()
            comparison.beginEditing(isShowingCompared ? .compared : .base)
        }
        let old = version.profile
        editor.apply { draft in
            draft = draft.withCorrection(of: old)
            draft.name = old.name
            draft.optimizedSampleRate = old.optimizedSampleRate
            draft.engine = old.engine
            draft.linearPhaseToleranceDB = old.linearPhaseToleranceDB
        }
    }

    private var clearHistoryTitle: String {
        guard let editor = activeEditor else { return "" }
        let count = profileManager.history.versions(of: editor.original.id).count
        let versions = count == 1 ? "the earlier version" : "the \(count) earlier versions"
        return "Delete \(versions) of “\(editor.original.name)”?"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let editor = activeEditor {
            EQManagerPresetDetail(
                editor: editor,
                templateName: profileManager.templateName(of: editor.draft),
                comparison: detailComparison,
                color: isShowingCompared ? EQResponseGraph.comparedCurveColor : EQResponseGraph.baseCurveColor
            )
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 28))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text("No preset selected")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text("Choose a preset, or create a new one.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Button("Choose Preset...") { chooserPurpose = .select }
                .controlSize(.regular)
                .padding(.top, DesignTokens.Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func toggleFavorite(_ id: String) {
        if settings.isAutoEQFavorite(id: id) {
            settings.unfavoriteAutoEQProfile(id: id)
        } else {
            settings.favoriteAutoEQProfile(id: id)
        }
    }

    private func save(_ editor: EQManagerEditor) {
        // Commit a value still being typed in a field before reading the draft.
        NSApp.keyWindow?.makeFirstResponder(nil)
        switch AutoEQProfileManager.saveKind(original: editor.original, draft: editor.draft) {
        case .createPreset:
            requestNewPreset(from: editor)
        case .updateInPlace:
            if settings.appSettings.confirmPresetSaves {
                isSaveConfirmationPresented = true
            } else {
                saveInPlace(editor)
            }
        }
    }

    private var saveConfirmationMessage: String {
        guard let editor = activeEditor else { return "" }
        let limit = settings.appSettings.presetHistoryLimit
        let kept = limit > 0
            ? "The current version is kept in its history (the last \(limit) are kept), where it can be restored."
            : "The current version will be replaced: version history is off in Settings."
        return editor.original.isTemplate
            ? "Its bands stay as imported: only its name, base rate and correction change. \(kept)"
            : kept
    }

    private func saveInPlace(_ editor: EQManagerEditor) {
        guard let saved = profileManager.saveInPlace(editor.draft) else {
            alertMessage = "Could not save the preset."
            return
        }
        editor.markSaved(saved)
        audioEngine.reapplyAutoEQProfile(id: saved.id)
    }

    /// Ask for the name of a new preset holding the draft.
    private func requestNewPreset(from editor: EQManagerEditor) {
        let original = editor.original
        let draft = editor.draft
        let name: String
        if draft.name != original.name {
            name = draft.name
        } else {
            name = original.isTemplate ? "\(draft.name) (Custom)" : "\(draft.name) (Copy)"
        }
        let deviceUIDs = settings.deviceUIDs(usingAutoEQProfile: original.id)
        let names = deviceUIDs.compactMap { uid in audioEngine.outputDevices.first { $0.uid == uid }?.name }
        newPresetRequest = EQManagerNewPresetRequest(
            sourceName: original.name,
            sourceIsTemplate: original.isTemplate,
            suggestedName: name,
            deviceNames: names,
            otherDeviceCount: deviceUIDs.count - names.count
        )
    }

    private func createPreset(named name: String, useOnDevices: Bool) {
        guard let editor = activeEditor else { return }
        let isCompared = isShowingCompared
        let sourceID = editor.original.id
        guard let preset = profileManager.saveAsNewPreset(editor.draft, name: name) else {
            alertMessage = "Could not save the preset."
            return
        }
        if useOnDevices {
            audioEngine.switchAutoEQProfile(
                from: sourceID, to: preset.id,
                onDevices: settings.deviceUIDs(usingAutoEQProfile: sourceID)
            )
        }
        // The edited profile is left as it was; show the new preset in its place
        if isCompared {
            comparison.replaceCompared(with: EQManagerEditor(profile: preset))
        } else {
            self.editor = EQManagerEditor(profile: preset)
        }
    }

    /// Store a conversion as a new preset and show it. The converted preset is left as it was.
    private func createConvertedPreset(_ profile: AutoEQProfile, named name: String) {
        guard let preset = profileManager.saveAsNewPreset(profile, name: name) else {
            alertMessage = "Could not save the preset."
            return
        }
        editor = EQManagerEditor(profile: preset)
    }

    /// Replace the bands and preamp of the draft (one undo step); name, engine and source stay.
    private func replaceContents(with profile: AutoEQProfile) {
        activeEditor?.apply { draft in
            draft.kind = profile.kind
            draft.filters = profile.filters
            draft.curve = profile.curve
            draft.preampDB = profile.preampDB
            draft.optimizedSampleRate = profile.optimizedSampleRate
        }
    }

    /// Go back to the bands of the template the preset was made from.
    private func replaceContents(withTemplate templateID: String) {
        Task { @MainActor in
            if let template = await profileManager.resolveProfile(for: templateID) {
                replaceContents(with: template)
            } else {
                alertMessage = "The template of this preset is not available."
            }
        }
    }

    private func replaceContents(withFileAt url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = AutoEQParser.decodeText(data),
              var parsed = AutoEQParser.parse(text: text, name: url.deletingPathExtension().lastPathComponent, source: .imported)
        else {
            alertMessage = "Could not read \(url.lastPathComponent). Check the file format."
            return
        }
        // A text file does not say which rate its filters were made for: keep the preset's
        // (changeable in the Base rate row)
        if let draft = activeEditor?.draft {
            parsed.optimizedSampleRate = draft.kind == .parametric ? draft.optimizedSampleRate : AutoEQBaseRate.lastImportRate
        }
        replaceContents(with: parsed)
    }
}

// MARK: - New Preset Sheet

/// What the "new preset" sheet shows: where the changes come from and which devices use it.
struct EQManagerNewPresetRequest: Identifiable {
    let id = UUID()
    let sourceName: String
    let sourceIsTemplate: Bool
    let suggestedName: String
    /// Connected devices whose correction is the edited profile.
    let deviceNames: [String]
    /// Disconnected devices whose correction is the edited profile.
    let otherDeviceCount: Int

    var hasDevices: Bool { !deviceNames.isEmpty || otherDeviceCount > 0 }

    var devicesText: String {
        var parts = deviceNames
        if otherDeviceCount > 0 {
            parts.append(otherDeviceCount == 1 ? "1 disconnected device" : "\(otherDeviceCount) disconnected devices")
        }
        return ListFormatter.localizedString(byJoining: parts)
    }
}

/// Names the preset that receives the changes of a template or a copied preset.
@MainActor
struct EQManagerNewPresetSheet: View {
    let request: EQManagerNewPresetRequest
    let onCreate: (_ name: String, _ useOnDevices: Bool) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var useOnDevices = true

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("New Preset")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text(request.sourceIsTemplate
                 ? "“\(request.sourceName)” is a template: it stays as imported, and your changes become a new preset."
                 : "Your changes become a new preset. “\(request.sourceName)” stays as it is.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if request.hasDevices {
                Toggle(isOn: $useOnDevices) {
                    Text("Use it instead of “\(request.sourceName)” on \(request.devicesText)")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create Preset") { onCreate(trimmedName, useOnDevices && request.hasDevices) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 400, height: request.hasDevices ? 230 : 190)
        .onAppear { name = request.suggestedName }
    }
}

// MARK: - Preset Selector Button

/// Top-left control showing the preset being viewed; opens the preset chooser.
@MainActor
struct EQManagerPresetSelectorButton: View {
    let preset: AutoEQProfile?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset?.name ?? "Choose a preset")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(preset == nil ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                    if let preset {
                        Text(preset.attributesSummary)
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: DesignTokens.Spacing.md)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(width: 320, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? DesignTokens.Colors.pickerHover : DesignTokens.Colors.pickerBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel("Preset: \(preset?.name ?? "none")")
        .accessibilityHint("Choose a preset or create a new one")
    }
}

// MARK: - Favorite Button

/// Star toggle; favorites are the presets listed in the AutoEQ popup.
@MainActor
struct EQManagerFavoriteButton: View {
    let isFavorite: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isFavorite || isHovered ? DesignTokens.Colors.interactiveActive : DesignTokens.Colors.interactiveDefault)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isFavorite ? "Remove from favorites (hides it from the AutoEQ popup)" : "Add to favorites (shows it in the AutoEQ popup)")
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
    }
}

// MARK: - Hear Segments

/// The versions the devices can play, as segments: each its own width, the chosen one filled in
/// the color of its preset (the accent color for the preset of the top bar, orange for the
/// compared one).
private struct EQManagerHearSegments: View {
    let versions: [EQManagerComparison.Version]
    let selection: EQManagerComparison.Version
    let title: (EQManagerComparison.Version) -> String
    let onSelect: (EQManagerComparison.Version) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(versions.enumerated()), id: \.element) { index, version in
                if index > 0 {
                    separator(between: versions[index - 1], and: version)
                }
                segment(version)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
        .fixedSize()
    }

    /// A thin line between two segments, hidden beside the chosen one, as in a native segmented
    /// control. It keeps its width when hidden, so nothing moves.
    private func separator(between left: EQManagerComparison.Version, and right: EQManagerComparison.Version) -> some View {
        let isHidden = left == selection || right == selection
        return Rectangle()
            .fill(Color.primary.opacity(isHidden ? 0 : 0.2))
            .frame(width: 1, height: 14)
    }

    private func segment(_ version: EQManagerComparison.Version) -> some View {
        let isSelected = version == selection
        let isCompared = version == .compared || version == .comparedEdited
        let color = isCompared ? EQResponseGraph.comparedCurveColor : EQResponseGraph.baseCurveColor
        return Button {
            onSelect(version)
        } label: {
            Text(title(version))
                // The size and weight of a native segmented control's titles
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? color : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
