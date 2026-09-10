import SwiftUI

/// A compact library in the existing navigator column. The workspace keeps
/// ownership of opening, so this surface cannot bypass its I/O lifecycle.
public struct SavedVaultsView: View {
    private let store: SavedVaultStore
    private let currentRoot: URL?
    private let canSave: Bool
    @Binding private var isExpanded: Bool
    private let onSave: () -> Void
    private let onOpen: (URL) -> Void
    private let onError: (String) -> Void

    public init(
        store: SavedVaultStore,
        currentRoot: URL?,
        canSave: Bool,
        isExpanded: Binding<Bool>,
        onSave: @escaping () -> Void,
        onOpen: @escaping (URL) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.store = store
        self.currentRoot = currentRoot
        self.canSave = canSave
        _isExpanded = isExpanded
        self.onSave = onSave
        self.onOpen = onOpen
        self.onError = onError
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: GlassTheme.Spacing.snug) {
                if let error = store.loadError {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset Saved List") { store.reset() }
                        .controlSize(.small)
                } else {
                    if store.vaults.isEmpty {
                        Text("Save a vault to reopen it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: GlassTheme.Spacing.tight) {
                                ForEach(store.vaults) { vault in
                                    row(vault)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(store.vaults.count) * 52, 180))
                    }
                    Button(action: onSave) {
                        Label(
                            currentRoot.map { store.contains($0) } == true
                                ? "Current Vault Saved" : "Save Current Vault",
                            systemImage: "bookmark")
                    }
                    .controlSize(.small)
                    .disabled(!canSave)
                    .accessibilityIdentifier("vaults.saveCurrent")
                }
            }
            .padding(.top, GlassTheme.Spacing.tight)
        } label: {
            HStack {
                Text("Saved Vaults")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(store.vaults.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(GlassTheme.Spacing.snug)
    }

    private func row(_ vault: SavedVault) -> some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Button { onOpen(vault.url) } label: {
                HStack(spacing: GlassTheme.Spacing.tight) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vault.name)
                            .font(.callout)
                            .lineLimit(1)
                        Text(vault.url.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if currentRoot?.path == vault.url.path {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, GlassTheme.Spacing.tight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vault.url.path)
            .accessibilityLabel("Open saved vault \(vault.name)")
            .accessibilityValue(vault.url.path)
            Button {
                do { try store.remove(vault) }
                catch { onError(error.localizedDescription) }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
                    .controlTarget(Circle(), padding: GlassTheme.Spacing.tight)
            }
            .buttonStyle(.plain)
            .help("Remove from Saved Vaults. Files stay in place.")
            .accessibilityLabel("Remove \(vault.name) from Saved Vaults")
            .accessibilityValue(vault.url.path)
        }
    }
}
