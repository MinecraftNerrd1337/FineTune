// FineTune/Views/EQManager/EQManagerPresetChooser.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet of the EQ Manager window: pick the preset to view, create an empty one,
/// or import a ParametricEQ.txt or GraphicEQ.txt file (AutoEQ, Wavelet, Equalizer APO).
/// The library lists the user's presets, then the templates (imported files and downloaded
/// catalog profiles), whose changes are saved as new presets.
@MainActor
struct EQManagerPresetChooser: View {
    @Bindable var settings: SettingsManager
    let profileManager: AutoEQProfileManager
    let selectedPresetID: String?
    var title = "Choose a Preset"
    /// Shows the New Preset and Import buttons.
    var allowsCreation = true
    /// A device and the preset it uses.
    struct InUse {
        let deviceName: String
        let presetID: String
    }

    /// The device listened on and the preset it uses, listed first to go back to it.
    var inUse: InUse? = nil
    let onChoose: (AutoEQProfile) -> Void
    /// Lists the preset shown first, with a cross on hover that shows none without choosing
    /// another preset.
    var onDeselect: (() -> Void)? = nil
    /// A filter list picked to import: the chooser closes, and its base rate is asked for in a
    /// sheet of its own. Without it, the list is imported at the last rate chosen.
    var onImportFilterList: ((EQManagerImportRequest) -> Void)? = nil
    /// Offers Delete in the context menu of a preset or template of the library, after a
    /// confirmation. The caller deletes it and frees the devices that use it.
    var onDelete: ((_ profileID: String) -> Void)? = nil
    let onCancel: () -> Void

    private enum Mode { case choose, create }

    @State private var mode: Mode = .choose
    /// Searches the user's library by default; the AutoEQ catalog is opt-in.
    @State private var scope: AutoEQSearchScope = .library
    @State private var downloadingID: String?
    /// Bumped after a download so rows re-read the library.
    @State private var libraryRevision = 0
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchResult = AutoEQSearchResult(entries: [], totalCount: 0)
    @State private var hoveredID: String?
    /// The library profile whose deletion waits for confirmation.
    @State private var deleteCandidate: AutoEQCatalogEntry?
    @State private var loadingID: String?
    @State private var errorMessage: String?
    @State private var isImporterPresented = false

    @State private var newName = ""
    @State private var newKind: AutoEQPresetKind = .parametric
    @State private var newEngine: AutoEQCorrectionEngine = .minimumPhaseFIR
    @FocusState private var isSearchFocused: Bool

    private static let size = CGSize(width: 440, height: 480)

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .choose: chooseView
            case .create: createView
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.plainText]) { result in
            if case .success(let url) = result { importFile(url) }
        }
    }

    // MARK: - Choose

    private var chooseView: some View {
        VStack(spacing: 0) {
            header(title)

            searchField
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.sm)

            Picker("Search in", selection: $scope) {
                ForEach(AutoEQSearchScope.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.sm)

            Divider()

            list

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.top, DesignTokens.Spacing.xs)
            }

            Divider()

            HStack(spacing: DesignTokens.Spacing.sm) {
                if allowsCreation {
                    Button("New Preset...") {
                        newName = ""
                        mode = .create
                    }
                    Button("Import File...") { isImporterPresented = true }
                        .help("A ParametricEQ.txt or GraphicEQ.txt file from AutoEQ, Wavelet or Equalizer APO")
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DesignTokens.Spacing.md)
        }
        .onAppear { isSearchFocused = true }
        .onChange(of: searchText) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                debouncedQuery = newValue
            }
        }
        .onChange(of: debouncedQuery) { _, _ in runSearch() }
        .onChange(of: scope) { _, _ in runSearch() }
        .confirmationDialog(
            "Delete “\(deleteCandidate?.name ?? "")”?",
            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { entry in
            Button("Delete", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(deleteMessage(entry))
        }
    }

    // MARK: - Delete

    /// Presets and templates of the library; catalog profiles are not stored, so not deletable.
    private func isDeletable(_ entry: AutoEQCatalogEntry) -> Bool {
        onDelete != nil && profileManager.profile(for: entry.id)?.source.isLocal == true
    }

    private func deleteMessage(_ entry: AutoEQCatalogEntry) -> String {
        let devices = settings.deviceUIDs(usingAutoEQProfile: entry.id).count
        var text = "The preset and its version history are deleted. This cannot be undone."
        if devices > 0 {
            text += devices == 1
                ? " 1 device uses it: it will have no AutoEQ preset."
                : " \(devices) devices use it: they will have no AutoEQ preset."
        }
        return text
    }

    private func delete(_ entry: AutoEQCatalogEntry) {
        deleteCandidate = nil
        onDelete?(entry.id)
        libraryRevision += 1
        runSearch()
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            TextField(scope == .library ? "Search my library..." : "Search the AutoEQ catalog...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { searchText = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DesignTokens.Colors.pickerBackground)
        )
    }

    @ViewBuilder
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if debouncedQuery.isEmpty && scope == .catalog {
                    emptyMessage(catalogHint)
                } else if debouncedQuery.isEmpty {
                    let favorites = settings.favoriteAutoEQProfileIDs
                        .compactMap { profileManager.entry(for: $0) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    let presets = profileManager.localPresets.map { libraryEntry($0) }
                    let templates = profileManager.localTemplates.map { libraryEntry($0) }
                    let shortcuts = shortcutEntries
                    let hasShortcuts = shortcuts.shown != nil || shortcuts.inUse != nil

                    // Shortcuts first, without a title: the preset shown, then the one the device
                    // listened on uses (a single row when they are the same)
                    if let shown = shortcuts.shown {
                        row(shown, icon: shown.id == inUse?.presetID ? "ear" : nil, hoverKey: "shown", onDeselect: onDeselect)
                    }
                    if let inUseEntry = shortcuts.inUse {
                        row(inUseEntry, icon: "ear", hoverKey: "inUse")
                    }
                    // A favorite is listed twice (in Favorites and in its own section): each row
                    // gets an identity of its own, or the lazy stack leaves a blank row
                    if !favorites.isEmpty {
                        sectionTitle("Favorites", isFirst: !hasShortcuts)
                        ForEach(favorites.map { SectionEntry(section: "favorites", entry: $0) }) { row($0.entry) }
                    }
                    if !presets.isEmpty {
                        sectionTitle("My Presets", isFirst: !hasShortcuts && favorites.isEmpty)
                        ForEach(presets.map { SectionEntry(section: "presets", entry: $0) }) { row($0.entry) }
                    }
                    if !templates.isEmpty {
                        sectionTitle("Templates", isFirst: !hasShortcuts && favorites.isEmpty && presets.isEmpty)
                        ForEach(templates.map { SectionEntry(section: "templates", entry: $0) }) { row($0.entry) }
                    }
                    if favorites.isEmpty && presets.isEmpty && templates.isEmpty {
                        emptyMessage("No presets yet. Create one, import a file, or download one from the AutoEQ catalog.")
                    }
                } else if searchResult.entries.isEmpty {
                    emptyMessage("No presets found")
                } else {
                    ForEach(searchResult.entries) { row($0) }
                    if searchResult.totalCount > searchResult.entries.count {
                        Text("Showing \(searchResult.entries.count) of \(searchResult.totalCount) results")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                }
            }
            .padding(DesignTokens.Spacing.sm)
        }
        .frame(maxHeight: .infinity)
    }

    /// The rows listed before Favorites: the preset shown (captioned as in use when it is),
    /// and the preset the device listened on uses, when it is another one.
    private var shortcutEntries: (shown: AutoEQCatalogEntry?, inUse: AutoEQCatalogEntry?) {
        let inUseEntry = inUseEntry
        guard onDeselect != nil, let id = selectedPresetID, let shown = libraryOrCatalogEntry(id) else {
            return (nil, inUseEntry)
        }
        if let inUseEntry, inUseEntry.id == shown.id { return (inUseEntry, nil) }
        return (shown, inUseEntry)
    }

    /// The preset the device listened on uses, captioned with that device.
    private var inUseEntry: AutoEQCatalogEntry? {
        guard let inUse, let entry = libraryOrCatalogEntry(inUse.presetID) else { return nil }
        return AutoEQCatalogEntry(id: entry.id, name: entry.name,
                                  measuredBy: "In use on \(inUse.deviceName)", relativePath: entry.relativePath)
    }

    private func libraryOrCatalogEntry(_ id: String) -> AutoEQCatalogEntry? {
        profileManager.entry(for: id) ?? profileManager.profile(for: id).map { libraryEntry($0) }
    }

    private func libraryEntry(_ profile: AutoEQProfile) -> AutoEQCatalogEntry {
        AutoEQCatalogEntry(id: profile.id, name: profile.name, measuredBy: profileManager.libraryLabel(of: profile), relativePath: "")
    }

    private var catalogHint: String {
        let count = profileManager.catalogEntries.count
        switch profileManager.catalogState {
        case .loading where count == 0:
            return "Loading the AutoEQ catalog..."
        default:
            return count > 0
                ? "Type to search \(count) headphones in the AutoEQ catalog"
                : "The AutoEQ catalog is not available right now"
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.lg)
    }

    private func runSearch() {
        searchResult = profileManager.search(query: debouncedQuery, limit: 100, scope: scope)
    }

    /// A row of one section of the library list.
    private struct SectionEntry: Identifiable {
        let section: String
        let entry: AutoEQCatalogEntry
        var id: String { "\(section)/\(entry.id)" }
    }

    /// A section header; the ones after the first get more room above them.
    private func sectionTitle(_ title: String, isFirst: Bool) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.top, isFirst ? DesignTokens.Spacing.sm : DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.xxs)
    }

    /// A preset; `hoverKey` sets a shortcut row apart from the same preset in its section.
    /// `onDeselect` adds a cross on hover to the preset shown.
    private func row(
        _ entry: AutoEQCatalogEntry,
        icon: String? = nil,
        hoverKey: String? = nil,
        onDeselect: (() -> Void)? = nil
    ) -> some View {
        let isSelected = entry.id == selectedPresetID
        let hoverID = hoverKey.map { "\($0)/\(entry.id)" } ?? entry.id
        let isHovered = hoveredID == hoverID
        let isFavorite = settings.isAutoEQFavorite(id: entry.id)
        let _ = libraryRevision
        let isCatalogEntry = profileManager.profile(for: entry.id)?.source.isLocal != true
            && profileManager.catalogEntry(for: entry.id) != nil

        return HStack(spacing: DesignTokens.Spacing.sm) {
            if let icon { rowIcon(icon) }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                if !entry.measuredBy.isEmpty {
                    Text(entry.measuredBy)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if loadingID == entry.id {
                ProgressView().controlSize(.mini)
            }
            if scope == .catalog && isCatalogEntry {
                downloadControl(for: entry)
            }
            if isSelected, let onDeselect, isHovered {
                Button("Show No Preset", systemImage: "xmark.circle.fill", action: onDeselect)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .help("Show no preset, without choosing another one")
            } else if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: onDeselect == nil ? nil : 22)
            }
            Button {
                if isFavorite {
                    settings.unfavoriteAutoEQProfile(id: entry.id)
                } else {
                    settings.favoriteAutoEQProfile(id: entry.id)
                }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(isFavorite ? DesignTokens.Colors.interactiveActive : DesignTokens.Colors.interactiveDefault)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isFavorite || isHovered ? 1 : 0)
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: 34)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? hoverID : (hoveredID == hoverID ? nil : hoveredID) }
        .onTapGesture { choose(entry) }
        .accessibilityAddTraits(isSelected ? AccessibilityTraits([.isButton, .isSelected]) : .isButton)
        .overlay {
            if isDeletable(entry) {
                EQManagerDeleteMenu(title: entry.name) { deleteCandidate = entry }
            }
        }
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .frame(width: 16)
    }

    /// The preset shown keeps a tint, so it stands out without hovering.
    private func rowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor.opacity(isHovered ? 0.18 : isSelected ? 0.10 : 0))
    }

    @ViewBuilder
    private func downloadControl(for entry: AutoEQCatalogEntry) -> some View {
        if profileManager.libraryCopy(of: entry) != nil {
            Text("In My Library")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        } else if downloadingID == entry.id {
            ProgressView().controlSize(.mini)
        } else {
            Button {
                download(entry)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Download to My Library, as a template")
            .accessibilityLabel("Download \(entry.name) to My Library")
        }
    }

    // MARK: - Create

    private var createView: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            header("New Preset")

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                field("Name") {
                    TextField("My headphones", text: $newName)
                        .textFieldStyle(.roundedBorder)
                }
                field("Type") {
                    Picker("Type", selection: $newKind) {
                        ForEach(AutoEQPresetKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                field("Correction") {
                    Picker("Correction", selection: $newEngine) {
                        ForEach(AutoEQCorrectionEngine.available(for: newKind)) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: newKind) { _, kind in
                        if !AutoEQCorrectionEngine.available(for: kind).contains(newEngine) {
                            newEngine = .minimumPhaseFIR
                        }
                    }
                }
                Text(newEngine.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The preset starts empty. Band editing comes in a later version.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, DesignTokens.Spacing.lg)
            }

            Spacer()
            Divider()

            HStack {
                Button("Back") {
                    errorMessage = nil
                    mode = .choose
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            content()
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.sm)
    }

    // MARK: - Actions

    private func choose(_ entry: AutoEQCatalogEntry) {
        guard loadingID == nil else { return }
        errorMessage = nil
        if let profile = profileManager.profile(for: entry.id) {
            onChoose(profile)
            return
        }
        loadingID = entry.id
        Task { @MainActor in
            if let profile = await profileManager.resolveProfile(for: entry) {
                onChoose(profile)
            } else {
                errorMessage = "Could not load \(entry.name)"
            }
            loadingID = nil
        }
    }

    private func download(_ entry: AutoEQCatalogEntry) {
        guard downloadingID == nil else { return }
        errorMessage = nil
        downloadingID = entry.id
        Task { @MainActor in
            if await profileManager.downloadToLibrary(entry) == nil {
                errorMessage = "Could not download \(entry.name)"
            }
            downloadingID = nil
            libraryRevision += 1
        }
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        if let profile = profileManager.createPreset(name: trimmedName, kind: newKind, engine: newEngine) {
            onChoose(profile)
        } else {
            errorMessage = "Could not save the preset"
        }
    }

    /// Reads the file first: a filter list then asks for its base rate, a graphic curve (in Hz)
    /// is imported at once.
    private func importFile(_ url: URL) {
        errorMessage = nil
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url), let text = AutoEQParser.decodeText(data),
              let parsed = AutoEQParser.parse(text: text, name: name, source: .imported) else {
            errorMessage = "Could not read \(url.lastPathComponent). Check the file format."
            return
        }
        if parsed.kind == .parametric, let onImportFilterList {
            onImportFilterList(EQManagerImportRequest(url: url, name: name, bandCount: parsed.filters.count, preampDB: parsed.preampDB))
            return
        }
        if let profile = profileManager.importProfile(from: url, name: name, baseRate: AutoEQBaseRate.lastImportRate) {
            onChoose(profile)
        } else {
            errorMessage = "Could not read \(url.lastPathComponent). Check the file format."
        }
    }
}

// MARK: - Import Sheet

/// A filter list (ParametricEQ.txt) picked to import, read once to show what it holds.
struct EQManagerImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let bandCount: Int
    let preampDB: Float
}

/// Asks for the sample rate the filters of an imported filter list were designed for: the file
/// does not say it. A sheet of its own, so the question is not missed.
struct EQManagerImportSheet: View {
    let request: EQManagerImportRequest
    let onImport: (_ baseRate: Double) -> Void
    let onCancel: () -> Void

    @State private var baseRate = AutoEQBaseRate.lastImportRate

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Import “\(request.name)”")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(2)

            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Filters designed for")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Picker("Filters designed for", selection: $baseRate) {
                    ForEach(AutoEQBaseRate.choices, id: \.self) { Text(AutoEQBaseRate.label($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            Text("A filter list is made for one sample rate, which the file does not say. AutoEQ's own profiles are made for 44.1 kHz; other tools often use 48 kHz. If unsure, keep 44.1 kHz: it can be changed later in the preset's Base rate.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import") { onImport(baseRate) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 400, height: 250)
    }

    private var summary: String {
        let bands = request.bandCount == 1 ? "1 band" : "\(request.bandCount) bands"
        return "Filter list: \(bands), preamp \(String(format: "%+.1f", request.preampDB)) dB"
    }
}

// MARK: - Delete Menu

/// The right-click menu of a library row, drawn by AppKit: SwiftUI's contextMenu does not show
/// a red item. Headed with the preset's name, so a misclick shows which one it is about, then
/// Delete... in red.
struct EQManagerDeleteMenu: NSViewRepresentable {
    let title: String
    let onDelete: () -> Void

    func makeNSView(context: Context) -> RightClickView { RightClickView() }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.title = title
        view.onDelete = onDelete
    }

    final class RightClickView: NSView {
        var title = ""
        var onDelete: () -> Void = {}

        /// Takes right clicks (and control-clicks) only: the row under it keeps its hover,
        /// clicks and buttons.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isMenuClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(.sectionHeader(title: title))

            let label = "Delete..."
            let item = NSMenuItem(title: label, action: #selector(deleteChosen), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: label, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.menuFont(ofSize: 0),
            ])
            menu.addItem(item)
            return menu
        }

        @objc private func deleteChosen() { onDelete() }
    }
}
