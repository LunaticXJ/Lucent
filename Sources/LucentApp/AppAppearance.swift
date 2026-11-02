import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

enum AppTheme: String {
    case system, dark, light
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .dark: .dark; case .light: .light }
    }
    #if os(iOS) || os(tvOS)
    var interfaceStyle: UIUserInterfaceStyle {
        switch self { case .system: .unspecified; case .dark: .dark; case .light: .light }
    }
    #endif
    func isDark(system: ColorScheme) -> Bool { colorScheme.map { $0 == .dark } ?? (system == .dark) }
}
private struct AppThemeKey: EnvironmentKey { static let defaultValue = AppTheme.system }
extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Apply the saved preference once, above tabs/navigation and before async loading.
struct AppAppearance: ViewModifier {
    @AppStorage("lucent.appearance.theme") private var rawTheme = "system"
    func body(content: Content) -> some View {
        let theme = AppTheme(rawValue: rawTheme) ?? .system
        content
            .environment(\.appTheme, theme)
            .background(Color("AppBackground").ignoresSafeArea())
            #if os(iOS) || os(tvOS)
            .background(AppearanceWindowAnchor(style: theme.interfaceStyle).allowsHitTesting(false))
            #endif
            .preferredColorScheme(theme.colorScheme)
    }
}

/// UIKit's window must have the same preference before its first display pass.
/// Scope this to the attached scene; never change other windows or global UIKit appearance.
#if os(iOS) || os(tvOS)
private struct AppearanceWindowAnchor: UIViewRepresentable {
    let style: UIUserInterfaceStyle
    func makeUIView(context: Context) -> Anchor { Anchor(style: style) }
    func updateUIView(_ view: Anchor, context: Context) { view.style = style; view.apply() }
    final class Anchor: UIView {
        var style: UIUserInterfaceStyle
        init(style: UIUserInterfaceStyle) {
            self.style = style
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); apply() }
        func apply() {
            guard let window else { return }
            if window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
            window.backgroundColor = UIColor(named: "AppBackground")
        }
    }
}
#endif
