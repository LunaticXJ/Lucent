import SwiftUI
#if os(iOS)
import UIKit

final class LucentOrientationDelegate: NSObject, UIApplicationDelegate {
    static var playbackIsPresented = false
    private static var browsingOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? .portrait : .allButUpsideDown
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.playbackIsPresented ? .landscape : Self.browsingOrientations
    }

    static func setPlaybackPresented(_ presented: Bool) {
        playbackIsPresented = presented
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }
        (scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first)?
            .rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: presented ? .landscape : browsingOrientations))
    }
}
#endif

@main
struct LucentApp: App {
    @StateObject private var library = LibraryStore()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LucentOrientationDelegate.self) private var orientationDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
        }
    }
}
