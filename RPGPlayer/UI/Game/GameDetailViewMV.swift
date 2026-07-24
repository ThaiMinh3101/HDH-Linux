import SwiftUI

// MARK: - GameDetailViewMV
// SwiftUI wrapper around GamePlayerViewController.
// Used as the NavigationLink destination when the user taps an MV/MZ game card.
//
// M4 additions:
//   - Toolbar "Plugins" button opens PluginManagerView sheet
//   - .onAppear triggers WebViewPool.warmUp so WKWebView is pre-allocated
//     before the user taps (reduces cold-start time)

struct GameDetailViewMV: View {

    let entry: GameEntry

    @State private var showPluginManager = false

    var body: some View {
        GamePlayerRepresentable(entry: entry)
            // Ignore all safe area insets — the game must fill the entire screen
            .ignoresSafeArea()
            // Remove the navigation bar on this screen (also handled in
            // GamePlayerViewController.viewWillAppear, but belt-and-suspenders)
            .navigationBarHidden(true)
            .statusBarHidden(true)
            // M4: Plugins management sheet (only for MV/MZ — always true here since
            // this view is only reachable for MV/MZ games, but guard anyway)
            .toolbar {
                if entry.engine == .mv || entry.engine == .mz {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showPluginManager = true
                        } label: {
                            Image(systemName: "puzzlepiece.extension")
                        }
                        .accessibilityLabel("Quản lý plugin")
                    }
                }
            }
            .sheet(isPresented: $showPluginManager) {
                PluginManagerView(entry: entry)
            }
            // M4: Warm-up WKWebView before navigation animation completes
            // so a pre-allocated instance is ready when the VC builds its view.
            .onAppear {
                Task { @MainActor in
                    WebViewPool.shared.warmUp(for: entry)
                }
            }
    }
}

// MARK: - UIViewControllerRepresentable

private struct GamePlayerRepresentable: UIViewControllerRepresentable {

    let entry: GameEntry

    func makeUIViewController(context: Context) -> GamePlayerViewController {
        GamePlayerViewController(entry: entry)
    }

    func updateUIViewController(_ uiViewController: GamePlayerViewController, context: Context) {
        // No dynamic updates needed — game is stateful inside WKWebView
    }
}
