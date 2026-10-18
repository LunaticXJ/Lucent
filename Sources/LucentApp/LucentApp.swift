import SwiftUI
#if os(iOS)
import UIKit

final class LucentOrientationDelegate: NSObject, UIApplicationDelegate {
    static var playbackIsPresented = false

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.playbackIsPresented ? .landscape : .allButUpsideDown
    }

    static func setPlaybackPresented(_ presented: Bool) {
        playbackIsPresented = presented
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: presented ? .landscape : .allButUpsideDown))
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
