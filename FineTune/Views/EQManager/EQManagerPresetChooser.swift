// FineTune/Views/EQManager/EQManagerPresetChooser.swift
import SwiftUI
import UniformTypeIdentifiers

/// Sheet of the EQ Manager window: pick the preset to view, create an empty one,
/// or import a ParametricEQ.txt file.
@MainActor
struct EQManagerPresetChooser: View {
    @Bindable var settings: SettingsManager
    let profileManager: AutoEQProfileManager
    let selectedPresetID: String?
    var title = "Choose a Preset"
    /// Shows the New Preset and Import buttons.
    var allowsCreation = true
    let onChoose: (AutoEQProfile) -> Void
    let onCancel: () -> Void

    private enum Mode { case choose, create }

    @State private var mode: Mode = .choose
    /// Searches the user's presets by default; the AutoEQ catalog is opt-in.
    @State private var scope: AutoEQSearchScope = .library
    @State private var downloadingID: String?
    /// Bumped after a download so rows re-read the library.
    @State private var libraryRevision = 0
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchResult = AutoEQSearchResult(entries: [], totalCount: 0)
    @State private var hoveredID: String?
    @State private var loadingID: String?
    @State private var errorMessage: String?
    @State private var isImporterPresented = false

    @State private var newName = ""
    @State private var newKind: AutoEQPresetKind = .parametric
    @State private var newEngine: AutoEQCorrectionEngine = .exactFIR
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
                    Button("Import ParametricEQ.txt...") { isImporterPresented = true }
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
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            TextField(scope == .library ? "Search my presets..." : "Search the AutoEQ catalog...", text: $searchText)
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
                    let local = profileManager.localProfiles.map {
                        AutoEQCatalogEntry(id: $0.id, name: $0.name, measuredBy: $0.sourceLabel ?? "", relativePath: "")
                    }

                    if !favorites.isEmpty {
                        sectionTitle("Favorites")
                        ForEach(favorites) { row($0) }
                    }
                    if !local.isEmpty {
                        sectionTitle("My Presets")
                        ForEach(local) { row($0) }
                    }
                    if favorites.isEmpty && local.isEmpty {
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xxs)
    }

    private func row(_ entry: AutoEQCatalogEntry) -> some View {
        let isSelected = entry.id == selectedPresetID
        let isFavorite = settings.isAutoEQFavorite(id: entry.id)
        let _ = libraryRevision
        let isCatalogEntry = profileManager.profile(for: entry.id)?.source.isLocal != true
            && profileManager.catalogEntry(for: entry.id) != nil

        return HStack(spacing: DesignTokens.Spacing.sm) {
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
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
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
            .opacity(isFavorite || hoveredID == entry.id ? 1 : 0)
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hoveredID == entry.id ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? entry.id : (hoveredID == entry.id ? nil : hoveredID) }
        .onTapGesture { choose(entry) }
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func downloadControl(for entry: AutoEQCatalogEntry) -> some View {
        if profileManager.libraryCopy(of: entry) != nil {
            Text("In My Presets")
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
            .help("Download to My Presets")
            .accessibilityLabel("Download \(entry.name) to My Presets")
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
                        ForEach(AutoEQCorrectionEngine.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
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

    private func importFile(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        if let profile = profileManager.importProfile(from: url, name: name) {
            onChoose(profile)
        } else {
            errorMessage = "Could not read \(url.lastPathComponent). Check the file format."
        }
    }
}
