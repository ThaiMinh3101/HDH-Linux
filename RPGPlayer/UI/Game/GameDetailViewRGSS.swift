// RPGPlayer/UI/Game/GameDetailViewRGSS.swift
//
// SwiftUI wrapper around RGSSViewController.
// Launch destination cho game RGSS (M6.0: chỉ VX Ace — XP/VX sau).
//
// Set gamePath + gameEntryForTranslation TRƯỚC viewDidLoad của RGSSViewController
// để nó load Data/Scripts.rvdata2 từ sandbox đúng game.

import SwiftUI

struct GameDetailViewRGSS: View {

    let entry: GameEntry

    var body: some View {
        RGSSRepresentable(entry: entry)
            .ignoresSafeArea()
            .navigationBarHidden(true)
            .statusBarHidden(true)
    }
}

// MARK: - UIViewControllerRepresentable

private struct RGSSRepresentable: UIViewControllerRepresentable {

    let entry: GameEntry

    func makeUIViewController(context: Context) -> RGSSViewController {
        let vc = RGSSViewController()

        // Sandbox của game (Application Support/RPGPlayer/Games/<uuid>/)
        let sandboxURL = StorageManager.shared.sandboxURL(for: entry.id)
        // Zip có thể lồng 1 lớp subfolder → dùng ScriptLoader.resolveGameRoot
        vc.gamePath = ScriptLoader.resolveGameRoot(in: sandboxURL)

        // M5: overlay dịch thuật (chưa wire text hook — sẽ làm khi
        // Window_Message binding xong ở M6)
        vc.gameEntryForTranslation = entry

        return vc
    }

    func updateUIViewController(_ uiViewController: RGSSViewController, context: Context) {
        // Game engine là stateful bên trong RGSSViewController — không update dynamic
    }
}