// RPGPlayer/UI/Game/PluginManagerView.swift
//
// Sheet UI that displays and toggles plugins listed in js/plugins.js.
// Only shown for MV/MZ games. Writes changes atomically on Save.
//
// Milestone 4.

import SwiftUI

// MARK: - PluginManagerView

struct PluginManagerView: View {

    let entry: GameEntry

    @Environment(\.dismiss) private var dismiss

    @State private var plugins: [RPGPlugin] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var searchText = ""

    /// True when any plugin status differs from the loaded state
    @State private var isDirty = false
    @State private var originalStatuses: [String: Bool] = [:]

    /// Root directory for plugin files.
    /// MV/MZ games store js/plugins.js inside their www/ folder.
    /// PluginManager.loadPlugins(from:) looks for <root>/js/plugins.js.
    private var gameRoot: URL {
        let sandboxRoot = LibraryStore.shared.absoluteSandboxURL(for: entry)
        // Try www/ first (MV/MZ standard layout)
        let wwwURL = sandboxRoot.appendingPathComponent("www")
        if FileManager.default.fileExists(atPath: wwwURL.path) {
            return wwwURL
        }
        // Fallback: plugins.js at sandbox root (non-standard layout)
        return sandboxRoot
    }

    private var filteredPlugins: [RPGPlugin] {
        if searchText.isEmpty { return plugins }
        return plugins.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var enabledCount: Int { plugins.filter(\.status).count }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(white: 0.08).ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if let error = loadError {
                    errorView(error)
                } else if plugins.isEmpty {
                    emptyView
                } else {
                    pluginList
                }
            }
            .navigationTitle("Plugins")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Tìm plugin...")
            .toolbar { toolbarContent }
            .task { await loadPlugins() }
            .alert("Lỗi khi lưu", isPresented: Binding(
                get:  { saveError != nil },
                set:  { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                if let e = saveError { Text(e) }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Huỷ") {
                dismiss()
            }
            .foregroundStyle(.secondary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView().tint(.purple)
            } else {
                Button("Lưu") {
                    Task { await save() }
                }
                .fontWeight(.semibold)
                .foregroundStyle(isDirty ? .purple : .secondary)
                .disabled(!isDirty)
            }
        }
    }

    // MARK: - Plugin list

    private var pluginList: some View {
        List {
            // Summary header
            Section {
                HStack(spacing: 16) {
                    statBadge(
                        value: "\(enabledCount)",
                        label: "Bật",
                        color: .green
                    )
                    statBadge(
                        value: "\(plugins.count - enabledCount)",
                        label: "Tắt",
                        color: .orange
                    )
                    statBadge(
                        value: "\(plugins.count)",
                        label: "Tổng",
                        color: .secondary
                    )
                    Spacer()
                }
                .listRowBackground(Color(white: 0.12))

                if isDirty {
                    Label("Có thay đổi chưa lưu", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color(white: 0.12))
                }
            }

            // Warning
            Section {
                Label {
                    Text("Tắt plugin có thể gây lỗi nếu game phụ thuộc vào plugin đó.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                }
                .listRowBackground(Color(white: 0.12))
            }

            // Plugin rows
            Section(header: Text("Plugin (\(filteredPlugins.count))").foregroundStyle(.secondary)) {
                ForEach(filteredPlugins.indices, id: \.self) { i in
                    pluginRow(at: i)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.08))
    }

    private func pluginRow(at filteredIndex: Int) -> some View {
        // Find the original index in `plugins` array
        let filteredPlugin = filteredPlugins[filteredIndex]
        guard let masterIndex = plugins.firstIndex(where: { $0.id == filteredPlugin.id }) else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(spacing: 12) {
                // Status indicator dot
                Circle()
                    .fill(plugins[masterIndex].status ? Color.green : Color(white: 0.3))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(plugins[masterIndex].name)
                        .font(.system(.subheadline, design: .monospaced, weight: .medium))
                        .foregroundStyle(plugins[masterIndex].status ? .white : .secondary)

                    if !plugins[masterIndex].description.isEmpty {
                        Text(plugins[masterIndex].description)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { plugins[masterIndex].status },
                    set: { newVal in
                        plugins[masterIndex].status = newVal
                        checkDirty()
                    }
                ))
                .labelsHidden()
                .tint(.purple)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color(white: 0.12))
        )
    }

    // MARK: - Stat badge

    private func statBadge(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.purple)
                .scaleEffect(1.3)
            Text("Đang đọc plugins.js…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Game này không có plugin nào")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    @MainActor
    private func loadPlugins() async {
        isLoading = true
        loadError = nil

        let loaded = await Task.detached(priority: .userInitiated) {
            PluginManager.loadPlugins(from: gameRoot)
        }.value

        isLoading = false

        if let loaded {
            plugins = loaded
            // Snapshot original statuses to detect dirty state
            originalStatuses = Dictionary(uniqueKeysWithValues: loaded.map { ($0.name, $0.status) })
        } else {
            loadError = "Không tìm thấy js/plugins.js trong game này.\nGame có thể không dùng plugin."
        }
    }

    private func checkDirty() {
        isDirty = plugins.contains { plugin in
            originalStatuses[plugin.name] != plugin.status
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        saveError = nil

        let currentPlugins = plugins
        let root = gameRoot

        let error: Error? = await Task.detached(priority: .userInitiated) {
            do {
                try PluginManager.savePlugins(currentPlugins, to: root)
                return nil as Error?
            } catch {
                return error
            }
        }.value

        isSaving = false

        if let error {
            saveError = "Lưu thất bại: \(error.localizedDescription)"
        } else {
            // Update snapshot
            originalStatuses = Dictionary(uniqueKeysWithValues: plugins.map { ($0.name, $0.status) })
            isDirty = false
            dismiss()
        }
    }
}

#Preview {
    PluginManagerView(entry: GameEntry(
        name: "Test MZ Game",
        engine: .mz,
        relativeSandboxPath: "Games/preview/"
    ))
}
