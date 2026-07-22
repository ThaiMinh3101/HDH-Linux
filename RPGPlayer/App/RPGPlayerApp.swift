import SwiftUI

@main
struct RPGPlayerApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
    }
}
