import SwiftUI

/// Màn hình chính — thư viện game dạng lưới.
struct LibraryView: View {

    @State private var store = LibraryStore.shared
    @State private var showFilePicker = false
    @State private var showProgress = false
    @State private var showSettings  = false
    @State private var gameToDelete: GameEntry? = nil
    @State private var showDeleteConfirm = false

    // Layout lưới: 2 cột trên iPhone, 3 cột trên iPad
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ZStack {
            // Background gradient toàn màn hình
            backgroundView

            NavigationStack {
                mainContent
                    // d3 fix: English UI strings
                    .navigationTitle("Library")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { toolbarContent }
                    .preferredColorScheme(.dark)
                    .sheet(isPresented: $showSettings) {
                        SettingsView()
                    }
            }

            // Import progress overlay
            if showProgress {
                importProgressOverlay
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            handleFilePickerResult(result)
        }
        .task {
            // Kick off a background iCloud sync on app launch if enabled
            await CloudSaveManager.shared.startSync()
        }
        .confirmationDialog(
            "Delete Game?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Game and Saves", role: .destructive) {
                if let entry = gameToDelete {
                    store.deleteGame(entry)
                }
                gameToDelete = nil
            }
            Button("Cancel", role: .cancel) { gameToDelete = nil }
        } message: {
            if let name = gameToDelete?.name {
                Text("Deleting \"\(name)\" will remove all game files and save data. This cannot be undone.")
            }
        }
        .onChange(of: store.importState.isImporting) { _, newValue in
            if newValue {
                showProgress = true
            }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if store.games.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.games) { entry in
                        GameCardView(entry: entry) {
                            gameToDelete = entry
                            showDeleteConfirm = true
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .refreshable {
                store.load()
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.white.opacity(0.04))
                    .frame(width: 120, height: 120)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 8) {
                Text("No Games Yet")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Tap \"+\" to import your RPG Maker game\nfrom the Files app (.zip)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showFilePicker = true
            } label: {
                Label("Import Game", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Import overlay

    private var importProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .transition(.opacity)

            ImportProgressView(
                importState: $store.importState,
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showProgress = false
                    }
                }
            )
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .animation(.spring(duration: 0.3), value: showProgress)
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            Color(white: 0.06)

            // Subtle gradient blobs
            GeometryReader { geo in
                Circle()
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 300, height: 300)
                    .blur(radius: 80)
                    .offset(x: geo.size.width * 0.6, y: -50)

                Circle()
                    .fill(Color.blue.opacity(0.08))
                    .frame(width: 250, height: 250)
                    .blur(radius: 60)
                    .offset(x: -60, y: geo.size.height * 0.7)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .symbolEffect(.bounce, value: showFilePicker)
            }
            .accessibilityLabel("Import game")
        }
    }

    // MARK: - File picker handler

    private func handleFilePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                await store.importGame(from: url)
            }
        case .failure(let error):
            // Người dùng cancel không phải lỗi thật — chỉ log
            print("[LibraryView] fileImporter: \(error.localizedDescription)")
        }
    }
}

#Preview {
    LibraryView()
}
