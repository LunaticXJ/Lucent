import SwiftUI
import AVKit

#if os(macOS)
struct AudioRoutePicker: NSViewRepresentable {
    var player: AVPlayer? = nil
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) { view.player = player }
}
#else
struct AudioRoutePicker: UIViewRepresentable {
    var player: AVPlayer? = nil
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .white
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
