import Foundation
import JavaScriptCore

/// Which kind of Seanime provider — the two Shirox runs.
enum SeanimeProviderKind: String, Codable, Equatable {
    case manga, anime
}

/// A Seanime extension manifest, the part Shirox reads.
struct SeanimeManifest: Decodable, Equatable {
    let id: String
    let name: String
    let version: String
    let type: String
    let language: String?
    let lang: String?
    let payloadURI: String?
    let icon: String?
    let author: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, version, type, language, lang, payloadURI, icon, author
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = (try? c.decode(String.self, forKey: .version)) ?? "1.0.0"
        type = try c.decode(String.self, forKey: .type)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
        payloadURI = try? c.decodeIfPresent(String.self, forKey: .payloadURI)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
    }

    /// Shirox runs manga and streaming providers — never torrent providers.
    var kind: SeanimeProviderKind? {
        switch type {
        case "manga-provider": return .manga
        case "onlinestream-provider": return .anime
        default: return nil
        }
    }

    var isTypeScript: Bool { language?.lowercased() == "typescript" }

    /// A Seanime manifest rather than a Shirox one: no `sourceName`, and a Seanime type.
    static func detect(_ data: Data) -> SeanimeManifest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["sourceName"] == nil,
              let type = object["type"] as? String,
              ["manga-provider", "onlinestream-provider", "anime-torrent-provider", "custom-source", "plugin"].contains(type)
        else { return nil }
        return try? JSONDecoder().decode(SeanimeManifest.self, from: data)
    }
}

/// What a module remembers of the Seanime provider it is.
struct SeanimeProviderInfo: Codable, Equatable {
    let id: String
    let kind: SeanimeProviderKind
    /// "javascript" or "typescript" — as installed; the saved script is always JavaScript.
    let language: String
    let supportsDub: Bool
}

enum SeanimeInstallError: LocalizedError, Equatable {
    case unsupportedType
    case noScript
    case unsupportedHelpers([String])
    case typeScriptFailed
    case noProvider

    var errorDescription: String? {
        switch self {
        case .unsupportedType: return "Shirox runs Seanime manga and streaming providers only."
        case .noScript: return "This Seanime provider has no script to install."
        case .unsupportedHelpers(let names):
            return "This provider needs \(ListFormatter.localizedString(byJoining: names)), which Shirox doesn't support."
        case .typeScriptFailed: return "Shirox couldn't convert this provider's TypeScript."
        case .noProvider: return "This script doesn't define a Seanime provider."
        }
    }
}

/// The bundled Seanime scripts, and the checks made with them.
@MainActor
enum SeanimeScripts {
    static let runtimeSource: String? = bundled("SeanimeRuntime")
    private static let installSource: String? = bundled("SeanimeInstall")

    private static func bundled(_ name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Seanime helpers Shirox doesn't supply — a provider using one can't run here.
    static let unsupported = ["ChromeDP", "CryptoJS", "$torrentUtils", "$habari", "$database"]

    static func unsupportedHelpers(in script: String) -> [String] {
        unsupported.filter { name in
            let pattern = "(?<![A-Za-z0-9_$])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_$])"
            return script.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func stripTypeScript(_ code: String) -> String? {
        guard let installSource, let context = JSContext() else { return nil }
        context.evaluateScript(installSource)
        context.setObject(code, forKeyedSubscript: "__code" as NSString)
        let result = context.evaluateScript("__seanimeStripTypeScript(__code)")
        guard context.exception == nil, let js = result?.toString(), result?.isString == true else { return nil }
        return js
    }

    /// Whether the script defines a `Provider`, and whether its settings say it dubs.
    static func probe(_ script: String) -> (definesProvider: Bool, supportsDub: Bool) {
        guard let runtimeSource, let context = JSContext() else { return (false, false) }
        context.evaluateScript(runtimeSource)
        context.evaluateScript(script)
        guard context.exception == nil,
              context.evaluateScript("typeof Provider === 'function'")?.toBool() == true else { return (false, false) }
        let dubs = context.evaluateScript("""
        (() => { try { const p = new Provider(); const s = typeof p.getSettings === "function" ? p.getSettings() : null;
          return !!(s && s.supportsDub); } catch (e) { return false; } })()
        """)?.toBool() ?? false
        return (true, dubs)
    }
}

/// A Seanime manifest, installed as an ordinary Shirox module.
@MainActor
enum SeanimeInstaller {
    typealias Fetch = (URL) async throws -> Data

    static func module(from manifest: SeanimeManifest, manifestURL: URL,
                       fetch: Fetch = { try await URLSession.shared.data(from: $0).0 }) async throws -> ModuleDefinition {
        guard let kind = manifest.kind else { throw SeanimeInstallError.unsupportedType }
        guard let payload = manifest.payloadURI, let payloadURL = URL(string: payload),
              let source = String(data: try await fetch(payloadURL), encoding: .utf8), !source.isEmpty
        else { throw SeanimeInstallError.noScript }

        let missing = SeanimeScripts.unsupportedHelpers(in: source)
        guard missing.isEmpty else { throw SeanimeInstallError.unsupportedHelpers(missing) }

        let script: String
        if manifest.isTypeScript {
            guard let js = SeanimeScripts.stripTypeScript(source) else { throw SeanimeInstallError.typeScriptFailed }
            script = js
        } else {
            script = source
        }

        let probe = SeanimeScripts.probe(script)
        guard probe.definesProvider else { throw SeanimeInstallError.noProvider }

        var object: [String: Any] = [
            "sourceName": manifest.name, "version": manifest.version, "scriptUrl": payload,
            "type": kind == .manga ? "manga" : "anime",
        ]
        if let lang = manifest.lang, !lang.isEmpty { object["language"] = lang }
        if let icon = manifest.icon, !icon.isEmpty { object["iconUrl"] = icon }
        if let author = manifest.author, !author.isEmpty { object["author"] = ["name": author] }
        var module = try JSONDecoder().decode(ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        module.jsonUrl = manifestURL.absoluteString
        module.scriptContent = script
        module.seanime = SeanimeProviderInfo(id: manifest.id, kind: kind, language: manifest.language ?? "javascript",
                                             supportsDub: kind == .anime && probe.supportsDub)
        return module
    }
}
