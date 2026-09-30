import Foundation

/// Decides where mpv fetches a stream from.
@MainActor
protocol MPVRouter: AnyObject {
    /// The source mpv should open in place of `source`.
    func route(_ source: PlaybackSource) async -> PlaybackSource
    /// Lets go of whatever routing held up, once the engine is done.
    func release()
}

#if os(iOS)
/// Sends remote streams through the app's own proxy.
///
/// FFmpeg, which does mpv's networking, speaks only HTTP/1.1, and some CDNs refuse it: the
/// Cloudflare one behind AnimePahe's streams answered mpv 403 for exactly the request that
/// AVPlayer — on HTTP/2 — got 200 for, headers and all. The proxy fetches with URLSession, so
/// HTTP/2, attaches the stream's headers there, rewrites playlists so segments and keys come
/// back through it, and serves mpv over loopback.
@MainActor
final class MPVProxyRouter: MPVRouter {
    private static let reason = "mpv"
    private var holding = false

    func route(_ source: PlaybackSource) async -> PlaybackSource {
        guard let scheme = source.url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              !["127.0.0.1", "localhost"].contains(source.url.host?.lowercased() ?? "") else {
            // Files, and downloads already served over loopback, need no help.
            return source
        }
        await CastProxyServer.shared.startAndWait(headers: source.headers, reason: Self.reason)
        holding = true
        guard let proxied = CastProxyServer.shared.loopbackURL(for: source.url) else { return source }
        var routed = PlaybackSource(url: proxied)
        routed.prefersJapaneseAudio = source.prefersJapaneseAudio
        return routed
    }

    func release() {
        guard holding else { return }
        holding = false
        CastProxyServer.shared.stop(reason: Self.reason)
    }
}
#endif
