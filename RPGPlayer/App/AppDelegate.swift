import UIKit

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Orientation mask hiện tại — được GamePlayerViewController thay đổi runtime.
    /// Mặc định: portrait (màn hình thư viện).
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationMask
    }
}
