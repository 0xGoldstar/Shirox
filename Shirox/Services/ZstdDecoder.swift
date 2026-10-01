import Foundation
import libzstd

/// Zstandard, for the responses URLSession leaves compressed. It decodes gzip, deflate and Brotli
/// itself but not zstd, so a module that asked for zstd (fetchv2's Chrome and Firefox profiles do)
/// got the compressed bytes back as its text.
enum ZstdDecoder {

    enum Failure: Error, LocalizedError, Equatable {
        case corrupt(String)
        case truncated
        case tooLarge(limit: Int)

        var errorDescription: String? {
            switch self {
            case .corrupt(let reason): return "Could not decode zstd response: \(reason)"
            case .truncated:           return "Could not decode zstd response: it ends mid-frame"
            case .tooLarge(let limit): return "Could not decode zstd response: it's over \(limit >> 20) MB"
            }
        }
    }

    /// Every frame in `data`, one after another, since a server may send several. It uses the
    /// streaming decoder because a frame needn't say how big it is. It stops at `maxOutputBytes`,
    /// so a few hostile bytes can't expand into gigabytes.
    static func decompress(_ data: Data, maxOutputBytes: Int = 64 << 20) throws -> Data {
        guard let stream = ZSTD_createDStream() else { throw Failure.corrupt("out of memory") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        var scratch = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var output = Data()
        // 0 once the last frame is complete; anything else means the input stopped mid-frame.
        var pending = 0

        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            while true {
                let filledScratch = try scratch.withUnsafeMutableBytes { target -> Bool in
                    var out = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                    let result = ZSTD_decompressStream(stream, &out, &input)
                    if ZSTD_isError(result) != 0 {
                        throw Failure.corrupt(String(cString: ZSTD_getErrorName(result)))
                    }
                    output.append(target.baseAddress!.assumingMemoryBound(to: UInt8.self), count: out.pos)
                    pending = result
                    return out.pos == out.size
                }
                if output.count > maxOutputBytes { throw Failure.tooLarge(limit: maxOutputBytes) }
                // A full scratch buffer can mean more output is waiting even with no input left.
                if input.pos == input.size && !filledScratch { break }
            }
        }
        if pending != 0 { throw Failure.truncated }
        return output
    }
}

/// A response body the way a browser's fetch would hand it over.
enum HTTPBodyDecoding {

    /// zstd's frame magic, 0xFD2FB528 little-endian.
    static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// The body decoded if it's zstd, otherwise untouched. It checks the bytes as well as the
    /// header: if the system ever decodes zstd itself it may leave the header in place, and
    /// decoding a second time would fail.
    static func decoded(_ data: Data, response: HTTPURLResponse) throws -> Data {
        let encodings = (response.value(forHTTPHeaderField: "Content-Encoding") ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard encodings.contains("zstd"), data.starts(with: zstdMagic) else { return data }
        return try ZstdDecoder.decompress(data)
    }
}

extension URLSession {
    /// `data(for:)` with a zstd body decoded, since URLSession leaves those compressed. A body
    /// that says it's zstd but won't decode fails the request instead of passing on garbage.
    func decodedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { return (data, response) }
        return (try HTTPBodyDecoding.decoded(data, response: http), response)
    }
}
