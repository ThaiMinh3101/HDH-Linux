// RPGPlayer/UI/Settings/CleanupView.swift
//
// Milestone 4 — Storage Management UI
//
// Displays per-game disk usage broken down as:
//   • Asset: original imported game files
//   • Save: save data (Saves/)
//   • Cache: runtime-generated cache (Cache/)
//
// Actions:
//   • "Xóa cache" — deletes Cache/ folder, does not affect saves or game files
//   • "Xóa game" — confirms with alert, then deletes entire sandbox (game + saves)
//                  or optionally just game files (keeping saves not currently supported
//                  as saves are inside the sandbox — future: move saves outside sandbox)

import SwiftUI

// MARK: - CleanupView

struct CleanupView: View {

    @State private var store  = LibraryStore.shared
    @State private var items: [CleanupItem] = []
    @State private var isLoading = true
    @State private var gameToDelete: GameEntry? = nil
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            content
        }
        // d5 fix: English UI strings
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await loadSizes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .foregroundStyle(.secondary)
                .disabled(isLoading)
            }
        }
        .task { await loadSizes() }
        .confirmationDialog(
            "Delete Game?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Game and Saves", role: .destructive) {
                if let entry = gameToDelete {
                    deleteGame(entry)
                }
                gameToDelete = nil
            }
            Button("Cancel", role: .cancel) { gameToDelete = nil }
        } message: {
            if let name = gameToDelete?.name {
                Text("Deleting \"\(name)\" will remove all game files and saves. This cannot be undone.")
            }
        }
        .refreshable {
            await loadSizes()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Calculating storage…")
                .tint(.purple)
        } else if items.isEmpty {
            emptyView
        } else {
            gameList
        }
    }

    private var gameList: some View {
        List {
            // Total summary header
            Section {
                totalSummaryRow
            }

            // Per-game rows
            Section(header: Text("Games (\(items.count))").foregroundStyle(.secondary)) {
                ForEach(items) { item in
                    gameRow(item)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.08))
    }

    private var totalSummaryRow: some View {
        let totalAsset = items.reduce(0) { $0 + $1.assetBytes }
        let totalCache = items.reduce(0) { $0 + $1.cacheBytes }
        let totalSaves = items.reduce(0) { $0 + $1.savesBytes }
        let total      = totalAsset + totalCache + totalSaves

        return VStack(alignment: .leading, spacing: 10) {
            Text("Total Size")
                .font(.headline)
                .foregroundStyle(.white)

            HStack(spacing: 0) {
                usageBar(bytes: totalAsset, total: total, color: .blue)
                usageBar(bytes: totalSaves, total: total, color: .green)
                usageBar(bytes: totalCache, total: total, color: .orange)
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 16) {
                legendDot(color: .blue,   label: "Asset",  bytes: totalAsset)
                legendDot(color: .green,  label: "Save",   bytes: totalSaves)
                legendDot(color: .orange, label: "Cache",  bytes: totalCache)
            }

            Text(formatBytes(total))
                .font(.title2.bold())
                .foregroundStyle(.white)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color(white: 0.12))
    }

    private func gameRow(_ item: CleanupItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Game name + engine badge
            HStack(spacing: 8) {
                Text(item.entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(item.entry.engine.displayName)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(item.entry.engine.badgeColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Spacer()

                Text(formatBytes(item.totalBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Size breakdown
            HStack(spacing: 16) {
                sizeLabel("Asset",  bytes: item.assetBytes, color: .blue)
                sizeLabel("Save",   bytes: item.savesBytes, color: .green)
                sizeLabel("Cache",  bytes: item.cacheBytes, color: .orange)
            }

            // Action buttons
            HStack(spacing: 12) {
                // Delete cache — always shown, disabled if no cache
                Button {
                    deleteCacheFor(item.entry)
                } label: {
                    Label("Delete Cache", systemImage: "trash.slash")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.cacheBytes > 0 ? .orange : .secondary)
                }
                .disabled(item.cacheBytes == 0)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)

                Spacer()

                // Delete game
                Button(role: .destructive) {
                    gameToDelete   = item.entry
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Game", systemImage: "trash")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color(white: 0.12))
    }

    // MARK: - Sub views

    private func sizeLabel(_ title: String, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formatBytes(bytes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func legendDot(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text("\(label): \(formatBytes(bytes))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func usageBar(bytes: Int64, total: Int64, color: Color) -> some View {
        let fraction = total > 0 ? max(0.0, min(1.0, Double(bytes) / Double(total))) : 0
        if fraction > 0.001 {
            GeometryReader { geo in
                color
                    .frame(width: geo.size.width * fraction)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No games yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    @MainActor
    private func loadSizes() async {
        isLoading = true
        let games = store.games

        let loaded: [CleanupItem] = await Task.detached(priority: .utility) {
            games.map { entry in
                let sm = StorageManager.shared
                return CleanupItem(
                    entry:      entry,
                    assetBytes: sm.assetSize(for: entry.id),
                    cacheBytes: sm.cacheSize(for: entry.id),
                    savesBytes: sm.savesSize(for: entry.id)
                )
            }
        }.value

        items     = loaded.sorted { $0.totalBytes > $1.totalBytes }
        isLoading = false
    }

    private func deleteCacheFor(_ entry: GameEntry) {
        do {
            try StorageManager.shared.deleteCache(for: entry.id)
            // Refresh the row
            Task { await loadSizes() }
        } catch {
            print("[CleanupView] ❌ deleteCache failed: \(error)")
        }
    }

    private func deleteGame(_ entry: GameEntry) {
        store.deleteGame(entry)
        items.removeAll { $0.entry.id == entry.id }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle   = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - CleanupItem

private struct CleanupItem: Identifiable {
    var id: UUID { entry.id }
    let entry:      GameEntry
    let assetBytes: Int64
    let cacheBytes: Int64
    let savesBytes: Int64
    var totalBytes: Int64 { assetBytes + cacheBytes + savesBytes }
}

#Preview {
    NavigationStack {
        CleanupView()
    }
    .preferredColorScheme(.dark)
}
