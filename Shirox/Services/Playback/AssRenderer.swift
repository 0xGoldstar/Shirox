import CoreGraphics
import Foundation
import Libass

/// One frame of an ASS script: the lines on screen, as one premultiplied image, and where it
/// goes in the frame — in the frame's pixels, from its top-left corner.
struct AssFrame {
    let image: CGImage
    let rect: CGRect
}

/// Draws an ASS/SSA script with libass — styles, positions, karaoke, signs and the script's own
/// fonts — for AVPlayer, which has no renderer for them. mpv draws its own.
///
/// libass isn't thread-safe; every call to it goes through `queue`.
final class AssRenderer: @unchecked Sendable {

    enum Rendered {
        /// Nothing changed since the last frame.
        case unchanged
        /// What's on screen now; nil when nothing is.
        case frame(AssFrame?)
    }

    private let queue = DispatchQueue(label: "shirox.ass-renderer", qos: .userInitiated)
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let track: UnsafeMutablePointer<ASS_Track>
    private var frameSize = CGSize.zero
    private var storageSize = CGSize.zero
    private var fontScale = 1.0
    private var hasDrawn = false

    /// nil when libass can't read the script.
    init?(script: String) {
        guard let library = ass_library_init() else { return nil }
        // Fonts the script carries in its [Fonts] section.
        ass_set_extract_fonts(library, 1)
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            return nil
        }
        // CoreText finds the system's fonts; anything a script names that isn't there falls back.
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
        var bytes = Array(script.utf8)
        let track = bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.flatMap { base in
                base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    ass_read_memory(library, $0, buffer.count, nil)
                }
            }
        }
        guard let track else {
            ass_renderer_done(renderer)
            ass_library_done(library)
            return nil
        }
        self.library = library
        self.renderer = renderer
        self.track = track
    }

    deinit {
        let (track, renderer, library) = (track, renderer, library)
        queue.sync {
            ass_free_track(track)
            ass_renderer_done(renderer)
            ass_library_done(library)
        }
    }

    /// - Parameters:
    ///   - seconds: the script's clock.
    ///   - frameSize: the picture's size on screen, in pixels.
    ///   - storageSize: the video's own size, which the script was laid out against; zero if unknown.
    ///   - fontScale: 1 for the script's own sizes.
    ///   - force: draw even if nothing changed — after the overlay lost what it had.
    func render(at seconds: Double, frameSize: CGSize, storageSize: CGSize = .zero,
                fontScale: Double = 1, force: Bool = false) -> Rendered {
        queue.sync {
            let width = Int32(frameSize.width.rounded()), height = Int32(frameSize.height.rounded())
            guard width > 0, height > 0 else { return .frame(nil) }
            var settingsChanged = force || !hasDrawn
            if frameSize != self.frameSize {
                ass_set_frame_size(renderer, width, height)
                self.frameSize = frameSize
                settingsChanged = true
            }
            if storageSize != self.storageSize {
                ass_set_storage_size(renderer, Int32(storageSize.width.rounded()), Int32(storageSize.height.rounded()))
                self.storageSize = storageSize
                settingsChanged = true
            }
            if fontScale != self.fontScale {
                ass_set_font_scale(renderer, fontScale)
                self.fontScale = fontScale
                settingsChanged = true
            }
            var change: Int32 = 0
            let images = ass_render_frame(renderer, track, Int64((seconds * 1000).rounded()), &change)
            guard change != 0 || settingsChanged else { return .unchanged }
            hasDrawn = true
            return .frame(Self.composite(images))
        }
    }

    /// Blends libass's coverage bitmaps — each one colour — into one premultiplied BGRA image
    /// covering all of them.
    private static func composite(_ first: UnsafeMutablePointer<ASS_Image>?) -> AssFrame? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var node = first
        while let image = node?.pointee {
            if image.w > 0, image.h > 0 {
                minX = min(minX, Int(image.dst_x))
                minY = min(minY, Int(image.dst_y))
                maxX = max(maxX, Int(image.dst_x + image.w))
                maxY = max(maxY, Int(image.dst_y + image.h))
            }
            node = image.next
        }
        guard minX < maxX, minY < maxY else { return nil }
        let width = maxX - minX, height = maxY - minY, bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBufferPointer { out in
            var node = first
            while let image = node?.pointee {
                node = image.next
                guard image.w > 0, image.h > 0, let bitmap = image.bitmap else { continue }
                let r = Int(image.color >> 24 & 0xFF), g = Int(image.color >> 16 & 0xFF)
                let b = Int(image.color >> 8 & 0xFF)
                // libass stores transparency, not opacity.
                let opacity = 255 - Int(image.color & 0xFF)
                guard opacity > 0 else { continue }
                let originX = Int(image.dst_x) - minX, originY = Int(image.dst_y) - minY
                for y in 0..<Int(image.h) {
                    let row = bitmap + y * Int(image.stride)
                    var at = (originY + y) * bytesPerRow + originX * 4
                    for x in 0..<Int(image.w) {
                        let alpha = Int(row[x]) * opacity / 255
                        if alpha > 0 {
                            let keep = 255 - alpha
                            out[at] = UInt8((b * alpha + Int(out[at]) * keep) / 255)
                            out[at + 1] = UInt8((g * alpha + Int(out[at + 1]) * keep) / 255)
                            out[at + 2] = UInt8((r * alpha + Int(out[at + 2]) * keep) / 255)
                            out[at + 3] = UInt8((255 * alpha + Int(out[at + 3]) * keep) / 255)
                        }
                        at += 4
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return nil }
        return AssFrame(image: image, rect: CGRect(x: minX, y: minY, width: width, height: height))
    }
}
