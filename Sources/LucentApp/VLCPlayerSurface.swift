import SwiftUI
import VLCKit

#if os(macOS)
import AppKit
struct VLCPlayerSurface: NSViewRepresentable {
    let player: VLCMediaPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        player.drawable = view
        if player.media != nil { player.play() }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if (player.drawable as AnyObject?) !== view { player.drawable = view }
    }

}
#else
import UIKit
struct VLCPlayerSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        if player.media != nil { player.play() }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if (player.drawable as AnyObject?) !== view { player.drawable = view }
    }
}
#endif
