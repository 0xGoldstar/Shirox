import SwiftUI
import QuartzCore

/// Where a picture sits in a view.
enum VideoFrame {
    /// The rect a picture of `videoSize` takes in `bounds`: whole (fit), or covering it and
    /// overhanging (fill). The whole of `bounds` while the size isn't known.
    static func rect(videoSize: CGSize, in bounds: CGRect, filled: Bool) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let widthRatio = bounds.width / videoSize.width, heightRatio = bounds.height / videoSize.height
        let scale = filled ? max(widthRatio, heightRatio) : min(widthRatio, heightRatio)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

#if os(iOS) || os(macOS)
/// Draws an ASS script over AVPlayer's picture, every screen refresh, lined up with the picture
/// in Fit and Fill. It doesn't rise with the controls: signs belong where the script put them.
/// The platform views own the display link and call `tick`.
@MainActor
final class AssOverlayDriver {
    let layer = CALayer()
    private var renderer: AssRenderer?
    private var script: String?
    private weak var engine: AVPlayerEngine?
    private var filled = false
    private var visible = true
    private var delay = 0.0
    private var fontScale = 1.0
    private var needsRedraw = true
    private var rendering = false
    private let work = DispatchQueue(label: "shirox.ass-overlay", qos: .userInitiated)

    init() {
        layer.contentsGravity = .resize
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    func update(script: String, engine: AVPlayerEngine, filled: Bool, visible: Bool,
                delay: Double, fontScale: Double) {
        if script != self.script {
            self.script = script
            renderer = nil
            layer.contents = nil
            // A script with embedded fonts can be megabytes: read it off the main thread.
            work.async { [weak self] in
                let renderer = AssRenderer(script: script)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.script == script else { return }
                        self.renderer = renderer
                        self.needsRedraw = true
                    }
                }
            }
        }
        self.engine = engine
        if filled != self.filled || visible != self.visible || fontScale != self.fontScale {
            needsRedraw = true
        }
        self.filled = filled
        self.visible = visible
        self.delay = delay
        self.fontScale = fontScale
        layer.isHidden = !visible
    }

    /// One screen refresh: draws the script at the picture's time, once the last frame's done.
    func tick(bounds: CGRect, scale: CGFloat) {
        guard visible, !rendering, let renderer, let engine, scale > 0 else { return }
        let video = VideoFrame.rect(videoSize: engine.presentationSize, in: bounds, filled: filled)
        let pixels = CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
        let time = engine.currentTime + delay
        let storage = engine.presentationSize
        let fontScale = fontScale
        let force = needsRedraw
        needsRedraw = false
        rendering = true
        work.async { [weak self] in
            let rendered = renderer.render(at: time, frameSize: pixels, storageSize: storage,
                                           fontScale: fontScale, force: force)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rendering = false
                    guard case .frame(let frame) = rendered else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if let frame {
                        self.layer.contents = frame.image
                        self.layer.frame = CGRect(x: video.minX + frame.rect.minX / scale,
                                                  y: video.minY + frame.rect.minY / scale,
                                                  width: frame.rect.width / scale,
                                                  height: frame.rect.height / scale)
                    } else {
                        self.layer.contents = nil
                    }
                    CATransaction.commit()
                }
            }
        }
    }

    /// The layout moved under the last frame: draw again even if the script didn't change.
    func invalidate() { needsRedraw = true }
}
#endif

#if os(iOS)
import UIKit

struct PlayerAssOverlay: UIViewRepresentable {
    let script: String
    let engine: AVPlayerEngine
    var filled: Bool
    var visible: Bool
    var delay: Double
    var fontScale: Double

    func makeUIView(context: Context) -> AssOverlayView { AssOverlayView() }

    func updateUIView(_ view: AssOverlayView, context: Context) {
        view.driver.update(script: script, engine: engine, filled: filled, visible: visible,
                           delay: delay, fontScale: fontScale)
    }

    static func dismantleUIView(_ view: AssOverlayView, coordinator: ()) { view.stop() }
}

final class AssOverlayView: UIView {
    let driver = AssOverlayDriver()
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(driver.layer)
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        driver.invalidate()
    }

    fileprivate func tick() {
        guard let window else { return }
        driver.tick(bounds: bounds, scale: window.screen.scale)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// A display link holds its target strongly; this holds the view weakly.
    private final class DisplayLinkTarget {
        weak var view: AssOverlayView?
        init(_ view: AssOverlayView) { self.view = view }
        @objc func fire() { view?.tick() }
    }
}

#elseif os(macOS)
import AppKit

struct PlayerAssOverlay: NSViewRepresentable {
    let script: String
    let engine: AVPlayerEngine
    var filled: Bool
    var visible: Bool
    var delay: Double
    var fontScale: Double

    func makeNSView(context: Context) -> AssOverlayView { AssOverlayView() }

    func updateNSView(_ view: AssOverlayView, context: Context) {
        view.driver.update(script: script, engine: engine, filled: filled, visible: visible,
                           delay: delay, fontScale: fontScale)
    }

    static func dismantleNSView(_ view: AssOverlayView, coordinator: ()) { view.stop() }
}

final class AssOverlayView: NSView {
    let driver = AssOverlayDriver()
    private var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Top-left origin, as libass lays out.
        layer?.isGeometryFlipped = true
        layer?.addSublayer(driver.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        let link = displayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func layout() {
        super.layout()
        driver.invalidate()
    }

    fileprivate func tick() {
        guard let window else { return }
        driver.tick(bounds: bounds, scale: window.backingScaleFactor)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private final class DisplayLinkTarget {
        weak var view: AssOverlayView?
        init(_ view: AssOverlayView) { self.view = view }
        @objc func fire() { view?.tick() }
    }
}
#endif
