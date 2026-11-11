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
        guard playbackIsPresented != presented else { return }
        playbackIsPresented = presented
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }
        let root = (scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first)?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        var presentedController = root?.presentedViewController
        while let controller = presentedController {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            presentedController = controller.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: presented ? .landscape : browsingOrientations))
    }
}
#endif

@main
struct LucentApp: App {
    init() {
        #if os(iOS)
        UITabBar.appearance().tintColor = .label
        UITabBar.appearance().unselectedItemTintColor = .label
        #endif
        #if os(iOS) && DEBUG
        KeychainPasswordStore.importDebugMetadataCredential()
        #endif
    }
    @StateObject private var library = LibraryStore()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LucentOrientationDelegate.self) private var orientationDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
            #if os(iOS) && DEBUG
            if ProcessInfo.processInfo.environment["LUCENT_PLAYBACK_AUDIT"] == "1" {
                PlaybackAuditEntry().environmentObject(library)
            } else {
                libraryRoot
            }
            #else
            libraryRoot
            #endif
            }
            .modifier(AppAppearance())
        }
    }

    private var libraryRoot: some View {
        LibraryView()
            .environmentObject(library)
            .modifier(LocalizationEnvironment())
            #if os(iOS)
            .modifier(LaunchArtworkHandoff())
            #endif
    }

}

#if os(iOS)
private struct LaunchArtworkHandoff: ViewModifier {
    @State private var visible = true
    @State private var finishing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    ZStack(alignment: .topLeading) {
                        Image("LaunchLightAndShadow")
                            .resizable()
                            .frame(width: width, height: height)
                        Image(AppIconChoice.current.previewName)
                            .resizable()
                            .frame(width: width * 100 / 852, height: height * 100 / 1846)
                            .clipShape(RoundedRectangle(cornerRadius: width * 22 / 852))
                            .position(x: width * 152 / 852, y: height * 1620 / 1846)
                    }
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .opacity(finishing ? 0 : 1)
                .allowsHitTesting(!finishing)
                .task {
                    let fadeDuration = reduceMotion ? 0.15 : 0.32
                    do { try await Task.sleep(for: .seconds(2 - fadeDuration)) } catch { return }
                    withAnimation(.easeInOut(duration: fadeDuration)) {
                        finishing = true
                    } completion: {
                        visible = false
                    }
                }
            }
        }
    }
}
#endif

#if os(iOS) && DEBUG
private struct PlaybackAuditEntry: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var item: MediaItem?
    @State private var source: JellyfinItem.MediaSource?
    @State private var failure: String?
    var body: some View {
        Group {
            if let item {
                PlaybackView(item: item, serverMediaSourceID: source?.id,
                             serverContainer: source?.container,
                             serverDolbyVision: source?.mediaStreams?.contains(where: DolbyVisionSupport.isDolbyVision) == true)
            } else { ProgressView(failure ?? "Playback audit") }
        }
        .task {
            do {
                LucentOrientationDelegate.setPlaybackPresented(true)
                let environment = ProcessInfo.processInfo.environment
                guard let sourceID = environment["LUCENT_AUDIT_SOURCE_ID"].flatMap(UUID.init(uuidString:)),
                      let server = library.embySources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.embyToken(for: server.id) else {
                    throw NSError(domain: "Audit", code: 1)
                }
                guard let id = environment["LUCENT_AUDIT_ITEM"], !id.isEmpty else {
                    throw NSError(domain: "Audit", code: 2)
                }
                let remote = try await ServerDetailClient.item(baseAddress: server.baseAddress,
                    userID: server.userID, itemID: id, token: token)
                source = remote.mediaSources?.first
                var entry = MediaItem(title: remote.name,
                    location: .embyItem(sourceID: server.id, itemID: id), identity: remote.identity)
                entry.duration = remote.runTimeTicks.map { Double($0) / 10_000_000 }
                entry.position = 180
                entry.serverFileExtension = source?.container
                item = entry
            } catch { failure = error.localizedDescription; NSLog("Lucent audit entry failed: %@", failure ?? "") }
        }
    }
}
#endif
