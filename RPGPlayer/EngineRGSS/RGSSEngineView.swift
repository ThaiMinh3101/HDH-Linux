// RPGPlayer/EngineRGSS/RGSSEngineView.swift
//
// SwiftUI wrapper for RGSSViewController.
// Used by GameCardView (or a future GameDetailView) to launch RGSS games.

import SwiftUI
import UIKit

/// Wraps `RGSSViewController` for use in SwiftUI navigation hierarchies.
struct RGSSEngineView: UIViewControllerRepresentable {

    /// Root directory of the RGSS game (optional for M1b test mode).
    let gamePath: URL?

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> RGSSViewController {
        let vc = RGSSViewController()
        vc.gamePath = gamePath
        return vc
    }

    func updateUIViewController(_ uiViewController: RGSSViewController,
                                context: Context) {
        // M1b: no live updates needed.
    }
}

// MARK: - Preview
#Preview("RGSS Engine — M1b Hello Sprite") {
    RGSSEngineView(gamePath: nil)
        .ignoresSafeArea()
}
