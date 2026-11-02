# Startup appearance ownership

AppAppearance at the WindowGroup content is the single owner of the browsing theme.
It synchronously reads the saved system/dark/light preference before async catalog work.
An attached UIKit view applies the matching override to its own window on attachment,
covering the window background before SwiftUI's first display pass. System mode resets
the override to unspecified; other scenes are not modified.

MobileHomeView stores the extracted pair of dark/light poster colors, not a resolved Color.
Its displayed background is derived from that pair and the root appearance immediately.
Before extraction, the fallback already matches the root theme. Cached/load results can
change the hue, but cannot insert a stale dark color into the light theme or vice versa.
The LibraryView and home-level preferredColorScheme overrides have been removed. Player
and detail presentation-specific appearance remains scoped to those presentations.

The launch screen, empty window and root content share the AppBackground named color.
The OS-rendered launch screen uses the device appearance: static launch resources cannot
read Lucent's UserDefaults, so a manually selected app theme different from the device may
still have one OS-to-app transition. This does not involve repeated in-app theme changes.

References (platform APIs, no copied third-party code):
https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)
https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen/uicolorname

Build verification does not establish visual startup behavior. Manual checks: cold launch
in each of system/dark/light; manual app preference opposite the device preference; switch
system appearance; dismiss a dark player back to the saved browsing appearance. No automatic
UI or playback validation is performed by default under the project policy.
