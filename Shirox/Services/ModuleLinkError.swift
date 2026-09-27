import Foundation

/// Why a link given to Add Module isn't a module — named for what the link is,
/// with the link to paste instead.
enum ModuleLinkError: LocalizedError, Equatable {
    case unreachable(Int)
    case image
    case webPage
    case script
    case seanimeList
    case notAModule
    case adult

    var errorDescription: String? {
        switch self {
        case .unreachable(let status):
            return "That link answered with error \(status). Check it was copied in full."
        case .image:
            return "That link is an image, not a module. Paste the module's .json link instead."
        case .webPage:
            return "That link is a web page, not a module. On GitHub, open the file and use its Raw link."
        case .script:
            return "That link is a script, not a module. Paste the .json link beside it instead."
        case .seanimeList:
            return "That link is a list of modules. Adding a whole list isn't supported yet — paste one module's .json link."
        case .notAModule:
            return "That link isn't a module Shirox can add."
        case .adult:
            return "Shirox doesn't add adult modules."
        }
    }

    /// What a link that didn't decode as a module holds instead.
    static func diagnose(_ data: Data, response: URLResponse?, url: URL) -> ModuleLinkError {
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 { return .unreachable(status) }
        if isImage(data) || response?.mimeType?.hasPrefix("image/") == true { return .image }

        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if start.hasPrefix("<svg") || (start.hasPrefix("<?xml") && start.contains("<svg")) { return .image }
        if start.hasPrefix("<") { return .webPage }

        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let list = json as? [[String: Any]], list.contains(where: { $0["manifestURI"] != nil || $0["payloadURI"] != nil }) {
                return .seanimeList
            }
            return .notAModule
        }
        if ["js", "ts", "mjs", "cjs"].contains(url.pathExtension.lowercased())
            || text.contains("class Provider") || text.contains("function ") {
            return .script
        }
        return .notAModule
    }

    /// PNG, JPEG, GIF or WebP, by their opening bytes.
    private static func isImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<offset + signature.count]) == signature
        }
        return starts([0x89, 0x50, 0x4E, 0x47])
            || starts([0xFF, 0xD8, 0xFF])
            || starts(Array("GIF8".utf8))
            || (starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8))
    }
}
