// FineTune/Views/EQManager/EQManagerRootView.swift
import SwiftUI
import UniformTypeIdentifiers

/// Content of the "FineTune EQ Manager" window: a preset selector and edit controls on top,
/// the selected preset (response graph, preamp, bands) below.
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
        .fileImporter(isPresented: $isReplaceImporterPresented, allowedContentTypes: [.plainText]) { result in
            if case .success(let url) = result { replaceContents(withFileAt: url) }
        }
        .alert(
            alertMessage ?? "",
            isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
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
                if editor.isEditing {
                    editControls(editor)
                } else {
                    Button {
                        editor.beginEditing()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Make this preset editable")
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    @ViewBuilder
    private func editControls(_ editor: EQManagerEditor) -> some View {
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
        }
        .fixedSize()
        .help("Replace the bands and preamp of this preset (name and settings are kept)")

        Button(editor.hasChanges ? "Discard" : "Done") {
            editor.discard()
        }
        .help(editor.hasChanges ? "Drop all unsaved changes" : "Leave edit mode")

        Button(editor.draft.source.isLocal ? "Save" : "Save as Copy") {
            save(editor)
        }
        .keyboardShortcut("s", modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(!editor.hasChanges)
        .help(editor.draft.source.isLocal
              ? "Save the changes to this preset"
              : "Catalog presets stay untouched: the changes are saved as a new custom preset")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let editor {
            EQManagerPresetDetail(editor: editor)
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
        guard let saved = profileManager.saveEditedProfile(editor.draft) else {
            alertMessage = "Could not save the preset."
            return
        }
        editor.markSaved(saved)
        audioEngine.reapplyAutoEQProfile(id: saved.id)
    }

    /// Replace the bands and preamp of the draft (one undo step); name, engine and source stay.
    private func replaceContents(with profile: AutoEQProfile) {
        editor?.apply { draft in
            draft.kind = profile.kind
            draft.filters = profile.filters
            draft.preampDB = profile.preampDB
            draft.optimizedSampleRate = profile.optimizedSampleRate
        }
    }

    private func replaceContents(withFileAt url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = AutoEQParser.parse(text: text, name: url.deletingPathExtension().lastPathComponent, source: .imported)
        else {
            alertMessage = "Could not read \(url.lastPathComponent). Check the file format."
            return
        }
        replaceContents(with: parsed)
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
