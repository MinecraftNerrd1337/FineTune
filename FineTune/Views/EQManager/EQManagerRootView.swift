// FineTune/Views/EQManager/EQManagerRootView.swift
import SwiftUI
import UniformTypeIdentifiers

/// Content of the "FineTune EQ Manager" window: a preset selector and edit controls on top,
/// the selected preset (response graph, preamp, bands) below.
///
/// Saving follows the library's rules (`AutoEQProfileManager.saveKind`): a preset is saved in
/// place, after a confirmation (a setting) and with its replaced version kept in its history; a
/// template keeps its bands, so changing them saves a new preset. The Convert menu makes a new
/// preset from the one shown, in another form (`EQManagerConvertSheet`).
@MainActor
struct EQManagerRootView: View {
    static let title = "FineTune EQ Manager"
    /// Same height as the Settings window, 1.4x its width (720).
    static let size = CGSize(width: 1008, height: 560)

    @Bindable var settings: SettingsManager
    let audioEngine: AudioEngine

    /// What the preset chooser sheet is open for.
    private enum ChooserPurpose: String, Identifiable {
        case select, replace
        var id: String { rawValue }
    }

    @State private var editor: EQManagerEditor?
    @State private var chooserPurpose: ChooserPurpose?
    @State private var isReplaceImporterPresented = false
    @State private var alertMessage: String?
    @State private var isSaveConfirmationPresented = false
    @State private var newPresetRequest: EQManagerNewPresetRequest?
    @State private var isClearHistoryConfirmationPresented = false
    @State private var conversionRequest: EQManagerConversionRequest?

    private var profileManager: AutoEQProfileManager { audioEngine.autoEQProfileManager }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .sheet(item: $chooserPurpose) { purpose in
            EQManagerPresetChooser(
                settings: settings,
                profileManager: profileManager,
                selectedPresetID: purpose == .select ? editor?.draft.id : nil,
                title: purpose == .select ? "Choose a Preset" : "Replace Bands With a Preset",
                allowsCreation: purpose == .select,
                onChoose: { profile in
                    chooserPurpose = nil
                    switch purpose {
                    case .select: editor = EQManagerEditor(profile: profile)
                    case .replace: replaceContents(with: profile)
                    }
                },
                onCancel: { chooserPurpose = nil }
            )
            .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        }
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
                if let id = editor?.draft.id { profileManager.history.clear(profileID: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The preset itself is not changed. This cannot be undone.")
        }
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
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
                historyMenu(editor)
                convertMenu(editor)
                if editor.isEditing {
                    editControls(editor)
                } else {
                    Button {
                        editor.beginEditing()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help(editor.draft.isTemplate
                          ? "Templates keep their bands: changing them saves a new preset"
                          : "Make this preset editable")
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        // Only this dialog offers "Do not ask again" (the toggle applies to dialogs shown from here)
        .confirmationDialog(
            "Save changes to “\(editor?.original.name ?? "")”?",
            isPresented: $isSaveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Save") { if let editor { saveInPlace(editor) } }
            Button("Save as New Preset...") { if let editor { requestNewPreset(from: editor) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(saveConfirmationMessage)
        }
        .dialogSuppressionToggle(isSuppressed: Binding(
            get: { !settings.appSettings.confirmPresetSaves },
            set: { settings.appSettings.confirmPresetSaves = !$0 }
        ))
    }

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

    // MARK: - Convert

    /// New presets made from this one in another form. Outside edit mode only: a conversion
    /// starts from the stored preset.
    @ViewBuilder
    private func convertMenu(_ editor: EQManagerEditor) -> some View {
        if !editor.isEditing {
            let preset = editor.draft
            Menu {
                ForEach(EQManagerConversionKind.available(for: preset.kind)) { kind in
                    Button(kind.menuTitle) {
                        conversionRequest = EQManagerConversionRequest(kind: kind, source: preset)
                    }
                }
            } label: {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .fixedSize()
            .disabled(!preset.hasCorrection)
            .help(preset.hasCorrection
                  ? "Make a new preset from this one in another form. This preset is not changed."
                  : "This preset has no bands or curve to convert")
        }
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
            .disabled(editor.hasChanges)
            .help(editor.hasChanges
                  ? "Save or discard your changes to restore an earlier version"
                  : "Earlier versions of this preset. Restoring one opens it for editing: it replaces the current version only when saved.")
        }
    }

    private func versionLabel(_ version: AutoEQPresetVersion, current: AutoEQProfile) -> String {
        let date = version.replacedAt.formatted(date: .abbreviated, time: .shortened)
        let name = version.profile.name == current.name ? "" : "“\(version.profile.name)” · "
        return "\(date) · \(name)\(version.profile.attributesSummary)"
    }

    /// Load an earlier version into the draft (one undo step). Nothing is stored until saved.
    private func restore(_ version: AutoEQPresetVersion) {
        guard let editor else { return }
        if !editor.isEditing { editor.beginEditing() }
        let old = version.profile
        editor.apply { draft in
            draft = draft.withCorrection(of: old)
            draft.name = old.name
            draft.optimizedSampleRate = old.optimizedSampleRate
            draft.engine = old.engine
        }
    }

    private var clearHistoryTitle: String {
        guard let id = editor?.original.id else { return "" }
        let count = profileManager.history.versions(of: id).count
        let versions = count == 1 ? "the earlier version" : "the \(count) earlier versions"
        return "Delete \(versions) of “\(editor?.original.name ?? "")”?"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let editor {
            EQManagerPresetDetail(editor: editor, templateName: profileManager.templateName(of: editor.draft))
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
        guard let editor else { return "" }
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
        guard let editor else { return }
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
        // The edited profile is left as it was; show the new preset
        self.editor = EQManagerEditor(profile: preset)
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
        editor?.apply { draft in
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
        if let draft = editor?.draft {
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
