// FineTune/Views/Components/AutoEQSearchPanel.swift
import FluidMenuBarExtra
import SwiftUI

/// Panel for picking an AutoEQ correction preset for a device.
/// Two-zone layout: Status Zone (active preset or empty state)
/// above Favorites Zone (starred presets + EQ Manager button).
/// Browsing every preset happens in the EQ Manager window.
struct AutoEQSearchPanel: View {
    let profileManager: AutoEQProfileManager
    let favoriteIDs: Set<String>
    let selectedProfileID: String?
    let onSelect: (AutoEQProfile?) -> Void
    let onDismiss: () -> Void
    let onImport: () -> Void
    let importErrorMessage: String?
    var isCorrectionEnabled: Bool = false
    var onCorrectionToggle: ((Bool) -> Void)?
    var preampEnabled: Bool = true
    var onPreampToggle: (() -> Void)?
    /// The device whose AutoEQ this panel sets: the EQ Manager opens listening on it.
    var deviceUID: String?

    @State private var hoveredID: String?
    @State private var highlightedIndex: Int?
    @State private var loadingProfileID: String?
    @State private var fetchError: String?

    private let maxVisibleItems = 6
    private let itemHeight: CGFloat = 28
    private var listHeight: CGFloat { CGFloat(maxVisibleItems) * itemHeight }

    // MARK: - Favorites

    /// Starred presets (catalog, imported or created), minus the active one.
    private var resolvedFavorites: [AutoEQCatalogEntry] {
        favoriteIDs
            .compactMap { profileManager.entry(for: $0) }
            .filter { $0.id != selectedProfileID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolved display info for the status card.
    private var cardProfileInfo: (name: String, source: String?, attributes: String?)? {
        guard let selectedID = selectedProfileID else { return nil }
        if let profile = profileManager.profile(for: selectedID) {
            return (profile.name, profile.sourceLabel, profile.attributesSummary)
        } else if let entry = profileManager.entry(for: selectedID) {
            return (entry.name, entry.measuredBy, nil)
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            statusZone

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.xs)

            favoritesZone

            catalogError

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.xs)

            importButton

            errorMessages
        }
        .animation(.easeInOut(duration: 0.2), value: fetchError)
        .animation(.easeInOut(duration: 0.2), value: importErrorMessage)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .onKeyPress(.downArrow) {
            moveHighlight(direction: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveHighlight(direction: -1)
            return .handled
        }
        .onKeyPress(.return) {
            activateHighlighted()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    // MARK: - Status Zone

    @ViewBuilder
    private var statusZone: some View {
        if let selectedID = selectedProfileID, let info = cardProfileInfo {
            statusCard(id: selectedID, name: info.name, source: info.source, attributes: info.attributes)
                .transition(.opacity)
        } else if selectedProfileID != nil {
            statusCardLoading
                .transition(.opacity)
        } else {
            emptyStateView
                .transition(.opacity)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 20))
                .foregroundStyle(DesignTokens.Colors.autoEQEmptyIcon)

            Text("No correction active")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Text("Pick a favorite below")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(
                    DesignTokens.Colors.autoEQEmptyBorder,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
        )
        .padding(DesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No correction active. Pick a favorite below.")
    }

    // MARK: - Loading Placeholder

    private var statusCardLoading: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading profile...")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.autoEQEmptyBorder, lineWidth: 1)
        )
        .padding(DesignTokens.Spacing.sm)
    }

    // MARK: - Status Section (flat, no card container)

    @ViewBuilder
    private func statusCard(id: String, name: String, source: String?, attributes: String?) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            // Profile info + action buttons
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(name)
                        .font(DesignTokens.Typography.cardProfileName)
                        .foregroundStyle(
                            isCorrectionEnabled
                                ? DesignTokens.Colors.textPrimary
                                : DesignTokens.Colors.textSecondary
                        )
                        .lineLimit(1)

                    if let source {
                        Text(source)
                            .font(DesignTokens.Typography.cardSource)
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    if let attributes {
                        Text(attributes)
                            .font(DesignTokens.Typography.cardSource)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: DesignTokens.Spacing.xs) {
                    // Remove button
                    Button {
                        onSelect(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(
                                hoveredID == "_remove"
                                    ? DesignTokens.Colors.textSecondary
                                    : DesignTokens.Colors.textTertiary
                            )
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .whenHovered { hoveredID = $0 ? "_remove" : nil }
                    .accessibilityLabel("Remove correction profile")
                    .accessibilityHint("Returns to no correction state")
                }
            }

            // Mini toggle switches
            HStack(spacing: 10) {
                miniToggle(
                    label: "Correction",
                    isOn: isCorrectionEnabled
                ) { onCorrectionToggle?(!isCorrectionEnabled) }

                miniToggle(
                    label: "Preamp",
                    isOn: preampEnabled
                ) { onPreampToggle?() }

                Spacer()
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .animation(.easeInOut(duration: 0.15), value: isCorrectionEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) correction profile")
    }

    // MARK: - Mini Toggle

    private func miniToggle(
        label: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.autoEQToggleLabel)

            Toggle(
                label,
                isOn: Binding(get: { isOn }, set: { _ in action() })
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .scaleEffect(0.65)
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    // MARK: - Favorites Zone

    @ViewBuilder
    private var favoritesZone: some View {
        let favorites = resolvedFavorites
        if profileManager.catalogState == .loading && profileManager.catalogEntries.isEmpty && !favoriteIDs.isEmpty {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading favorites...")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: itemHeight * 2)
        } else if favorites.isEmpty {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Text(favoriteIDs.isEmpty ? "No favorites yet" : "No other favorites")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text("Add favorites in the EQ Manager to list them here")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textQuaternary)
            }
            .frame(maxWidth: .infinity, minHeight: itemHeight * 2)
            .padding(.vertical, DesignTokens.Spacing.xs)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        Text("FAVORITES")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .tracking(1.0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .padding(.top, DesignTokens.Spacing.xs)

                        ForEach(favorites) { entry in
                            catalogEntryRow(entry, itemIDPrefix: "fav_")
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
                .frame(height: min(listHeight, CGFloat(favorites.count) * (itemHeight + 2) + 30))
                .onChange(of: highlightedIndex) { _, _ in
                    scrollToHighlighted(proxy: proxy)
                }
            }
        }
    }

    // MARK: - Catalog Error

    @ViewBuilder
    private var catalogError: some View {
        if case .error(let message) = profileManager.catalogState,
           profileManager.catalogEntries.isEmpty {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                Text(message)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.red.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)
        }
    }

    // MARK: - EQ Manager Button

    private var importButton: some View {
        Button {
            // Without "Keep Panel Open", the AutoEQ popup and the menu bar panel step aside for the manager.
            // With it, both stay open.
            let stepAside = FluidMenuBarExtraBehavior.dismissesOnFocusLoss
            if stepAside { onDismiss() }
            EQManagerWindowController.shared.show(listeningOn: deviceUID)
            if stepAside { FluidMenuBarExtraBehavior.dismiss() }
        } label: {
            HStack {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 10))
                Text("Open EQ Manager...")
                    .font(.system(size: 11))
            }
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: itemHeight)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hoveredID == "_import" ? DesignTokens.Colors.hoverSurface : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .whenHovered { hoveredID = $0 ? "_import" : nil }
        .accessibilityLabel("Open EQ Manager")
        .accessibilityHint("Opens the FineTune EQ Manager window")
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    // MARK: - Error Messages

    @ViewBuilder
    private var errorMessages: some View {
        if let errorMessage = fetchError ?? importErrorMessage {
            Text(errorMessage)
                .font(.system(size: 10))
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xs)
                .transition(.opacity)
        }
    }

    // MARK: - Catalog Entry Row

    @ViewBuilder
    private func catalogEntryRow(_ entry: AutoEQCatalogEntry, itemIDPrefix: String) -> some View {
        let isSelected = entry.id == selectedProfileID
        let itemID = "\(itemIDPrefix)\(entry.id)"
        let isRowHovered = hoveredID == entry.id
        let isLoading = loadingProfileID == entry.id

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)

                Text(entry.measuredBy)
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: itemHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowHighlight(for: itemID, isHovered: isRowHovered))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectCatalogEntry(entry)
        }
        .accessibilityAddTraits(.isButton)
        .whenHovered { isHovered in
            hoveredID = isHovered ? entry.id : nil
            if isHovered { highlightedIndex = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Apply this correction profile")
    }

    // MARK: - Async Selection

    private func selectCatalogEntry(_ entry: AutoEQCatalogEntry) {
        guard loadingProfileID == nil else { return }
        loadingProfileID = entry.id
        fetchError = nil

        Task { @MainActor in
            if let profile = await profileManager.resolveProfile(for: entry) {
                onSelect(profile)
                onDismiss()
            } else {
                fetchError = "Failed to load \(entry.name)"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if fetchError != nil { fetchError = nil }
                }
            }
            loadingProfileID = nil
        }
    }

    // MARK: - Keyboard Navigation

    private func moveHighlight(direction: Int) {
        let items = resolvedFavorites
        guard !items.isEmpty else { return }

        if let current = highlightedIndex {
            let newIndex = current + direction
            if newIndex >= 0 && newIndex < items.count {
                highlightedIndex = newIndex
            }
        } else {
            highlightedIndex = direction > 0 ? 0 : items.count - 1
        }
        hoveredID = nil
    }

    private func activateHighlighted() {
        let items = resolvedFavorites
        guard let index = highlightedIndex, index < items.count else { return }
        selectCatalogEntry(items[index])
    }

    private func scrollToHighlighted(proxy: ScrollViewProxy) {
        let items = resolvedFavorites
        guard let index = highlightedIndex, index < items.count else { return }
        let profileID = items[index].id
        withAnimation(.easeOut(duration: 0.1)) {
            proxy.scrollTo(profileID, anchor: .center)
        }
    }

    // MARK: - Helpers

    private func isHighlighted(_ itemID: String) -> Bool {
        guard let index = highlightedIndex else { return false }
        let items = resolvedFavorites
        guard index < items.count else { return false }
        return "fav_\(items[index].id)" == itemID
    }

    private func rowHighlight(for itemID: String, isHovered: Bool) -> Color {
        (isHovered || isHighlighted(itemID)) ? Color.accentColor.opacity(0.15) : Color.clear
    }
}
