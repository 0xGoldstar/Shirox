import SwiftUI
import QuartzCore

#if os(iOS) || os(tvOS)
import UIKit

/// The MPV engine's picture: its Metal layer, kept the size of the view.
struct MPVVideoView: UIViewRepresentable {
    let engine: MPVEngine
    /// Crop to fill the screen rather than fit the whole picture.
    var filled = false

    func makeUIView(context: Context) -> MPVLayerHostView {
        MPVLayerHostView(hosting: engine.layer)
    }

    func updateUIView(_ view: MPVLayerHostView, context: Context) {
        view.hosted = engine.layer
        engine.setFillsScreen(filled)
    }
}

final class MPVLayerHostView: UIView {
    /// A new engine (a rebuild or a fallback) brings a new layer.
    var hosted: CALayer {
        didSet {
            guard oldValue !== hosted else { return }
            oldValue.removeFromSuperlayer()
            attach()
        }
    }

    init(hosting layer: CALayer) {
        hosted = layer
        super.init(frame: .zero)
        backgroundColor = .black
        attach()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func attach() {
        hosted.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        layer.addSublayer(hosted)
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.screen { hosted.contentsScale = screen.nativeScale }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // No implicit animation: the picture follows rotation and Fill at once.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}

#elseif os(macOS)
import AppKit

/// The MPV engine's picture: its Metal layer, kept the size of the view.
struct MPVVideoView: NSViewRepresentable {
    let engine: MPVEngine
    var filled = false

    func makeNSView(context: Context) -> MPVLayerHostView {
        MPVLayerHostView(hosting: engine.layer)
    }

    func updateNSView(_ view: MPVLayerHostView, context: Context) {
        view.hosted = engine.layer
        engine.setFillsScreen(filled)
    }
}

final class MPVLayerHostView: NSView {
    var hosted: CALayer {
        didSet {
            guard oldValue !== hosted else { return }
            oldValue.removeFromSuperlayer()
            attach()
        }
    }

    init(hosting layer: CALayer) {
        hosted = layer
        super.init(frame: .zero)
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        attach()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func attach() {
        hosted.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(hosted)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { hosted.contentsScale = window.backingScaleFactor }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}
#endif
