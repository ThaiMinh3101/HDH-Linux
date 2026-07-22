import SwiftUI

// MARK: - GameDetailViewMV
// SwiftUI wrapper around GamePlayerViewController.
// Used as the NavigationLink destination when the user taps an MV/MZ game card.

struct GameDetailViewMV: View {

    let entry: GameEntry

    var body: some View {
        GamePlayerRepresentable(entry: entry)
            // Ignore all safe area insets — the game must fill the entire screen
            .ignoresSafeArea()
            // Remove the navigation bar on this screen (also handled in
            // GamePlayerViewController.viewWillAppear, but belt-and-suspenders)
            .navigationBarHidden(true)
            .statusBarHidden(true)
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
