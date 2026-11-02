#if os(iOS)
import SwiftUI
import UIKit
import MediaPlayer
import AVFAudio

/// Gesture input is below the controls, so buttons and sliders retain ownership.
struct PlaybackGestureSurface: UIViewRepresentable {
    var enabled: Bool
    var singleTap: () -> Void
    var doubleTap: (CGFloat) -> Void
    var pan: (CGPoint, Bool, UIGestureRecognizer.State) -> Void
    var hold: (Bool) -> Void
    var pinch: (CGFloat) -> Void

    func makeUIView(context: Context) -> Surface { Surface(owner: self) }
    func updateUIView(_ view: Surface, context: Context) {
        view.owner = self
        if !enabled, view.holding || view.dragging {
            Task { @MainActor [weak view] in
                guard let view, !view.owner.enabled else { return }
                view.cancelActiveGestures()
            }
        }
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.cancelActiveGestures() }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        var owner: PlaybackGestureSurface
        var horizontal = false
        var holding = false
        var dragging = false
        init(owner: PlaybackGestureSurface) {
            self.owner = owner
            super.init(frame: .zero)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            let double = UITapGestureRecognizer(target: self, action: #selector(doubled(_:)))
            double.numberOfTapsRequired = 2
            tap.require(toFail: double)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.minimumPressDuration = 0.4
            hold.allowableMovement = 14
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            for recognizer in [tap, double, pan, hold, pinch] {
                recognizer.delegate = self
                addGestureRecognizer(recognizer)
            }
            accessibilityLabel = "播放画面"
            accessibilityTraits = .button
            isAccessibilityElement = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func accessibilityActivate() -> Bool { owner.singleTap(); return true }
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer is UITapGestureRecognizer, (recognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 1 { return true }
            guard owner.enabled, !UIAccessibility.isVoiceOverRunning else { return false }
            let point = recognizer.location(in: self)
            guard point.x > 24, point.x < bounds.width - 24, point.y > 24, point.y < bounds.height - 24 else { return false }
            if let pan = recognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: self)
                horizontal = abs(velocity.x) > abs(velocity.y) * 1.25
                if !horizontal && abs(velocity.y) < abs(velocity.x) * 1.25 { return false }
            }
            return true
        }
        func cancelActiveGestures() {
            if holding { holding = false; owner.hold(false) }
            if dragging { dragging = false; owner.pan(.zero, horizontal, .cancelled) }
            for recognizer in gestureRecognizers ?? [] where recognizer.state == .began || recognizer.state == .changed {
                recognizer.isEnabled = false; recognizer.isEnabled = true
            }
        }
        @objc func tapped() { owner.singleTap() }
        @objc func doubled(_ gesture: UITapGestureRecognizer) { owner.doubleTap(gesture.location(in: self).x / max(1, bounds.width)) }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            dragging = gesture.state == .began || gesture.state == .changed
            // x carries the initial side on begin, then normalized translation.
            let value = gesture.state == .began
                ? CGPoint(x: gesture.location(in: self).x / max(1, bounds.width), y: 0)
                : CGPoint(x: gesture.translation(in: self).x / max(1, bounds.width), y: gesture.translation(in: self).y / max(1, bounds.height))
            owner.pan(value, horizontal, gesture.state)
        }
        @objc func held(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { holding = true; owner.hold(true) }
            else if [.ended, .cancelled, .failed].contains(gesture.state), holding { holding = false; owner.hold(false) }
        }
        @objc func pinched(_ gesture: UIPinchGestureRecognizer) { if gesture.state == .ended { owner.pinch(gesture.scale) } }
    }
}

/// Keep a real MPVolumeView attached to the window; do not alter engine volumes,
/// which also participate in audio handover between playback engines.
struct PlaybackSystemVolume: UIViewRepresentable {
    let control: PlaybackVolumeControl
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 20))
        view.isUserInteractionEnabled = false
        control.view = view
        return view
    }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
@MainActor final class PlaybackVolumeControl: ObservableObject {
    weak var view: MPVolumeView?
    var value: Float { AVAudioSession.sharedInstance().outputVolume }
    func set(_ value: Float) {
        guard let slider = view?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(min(1, max(0, value)), animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

struct PlaybackGestureSettings: View {
    @AppStorage("lucent.gestures.doubleTap") private var doubleTap = "regional"
    @AppStorage("lucent.gestures.seek") private var seek = true
    @AppStorage("lucent.gestures.seekSpan") private var seekSpan = 120.0
    @AppStorage("lucent.gestures.brightness") private var brightness = true
    @AppStorage("lucent.gestures.volume") private var volume = true
    @AppStorage("lucent.gestures.hold") private var hold = true
    @AppStorage("lucent.gestures.holdRate") private var holdRate = 2.0
    @AppStorage("lucent.gestures.pinch") private var pinch = true
    @AppStorage("lucent.gestures.restoreBrightness") private var restoreBrightness = true
    var body: some View {
        Form {
            Section {
                Picker("双击画面", selection: $doubleTap) {
                    Text("左右快进退 · 中间播放暂停").tag("regional")
                    Text("播放 / 暂停").tag("playPause")
                    Text("关闭").tag("off")
                }.pickerStyle(.menu)
            }
            Section("滑动") {
                Toggle("横滑调整进度", isOn: $seek)
                if seek {
                    Picker("横滑一屏时长", selection: $seekSpan) {
                        ForEach([60.0, 120.0, 300.0], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                    }
                }
                Toggle("左侧竖滑调整亮度", isOn: $brightness)
                Toggle("右侧竖滑调整音量", isOn: $volume)
                Toggle("退出播放恢复亮度", isOn: $restoreBrightness)
            }
            Section {
                Toggle("长按临时倍速", isOn: $hold)
                if hold {
                    Picker("长按倍速", selection: $holdRate) {
                        ForEach([1.5, 2.0, 3.0], id: \.self) { Text("\($0.formatted(.number.locale(LocalizationPreferences.current.displayLocale)))×").tag($0) }
                    }
                }
                Toggle("双指缩放切换适应 / 铺满", isOn: $pinch)
            } footer: { Text("单击显示或隐藏控制栏。锁定画面后仅保留控制栏开关。") }
        }
            .modifier(LucentSettingsPageStyle())
        .navigationTitle("播放手势")
        .tint(.gray)
    }
}
#endif
