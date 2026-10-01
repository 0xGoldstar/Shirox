import Foundation
import SwiftUI
import Combine

/// Mirror of MangaModuleResolver's preference, for the anime side: keep the active
/// module if it's an anime (non-manga) module, else fall back to the first anime
/// module, else nil.
enum AnimeModulePreference {
    static func pick(active: ModuleDefinition?, modules: [ModuleDefinition]) -> ModuleDefinition? {
        if let active, active.isManga == false { return active }
        return modules.first { $0.isManga == false }
    }
}

@MainActor
final class ModuleManager: ObservableObject {
    static let shared = ModuleManager()

    @Published var modules: [ModuleDefinition] = []
    @Published var activeModule: ModuleDefinition?
    @Published var moduleReadyId: String? = nil
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Megabytes of scripts, kept out of UserDefaults (see `StoredFile`).
    private let storage = StoredFile(name: "modules.json", legacyKey: "savedModules")
    private let activeKey = "activeModuleId"

    private init() {
        loadFromStorage()
    }

    // MARK: - Add Module

    func addModule(from jsonURL: URL) async {
        isLoading = true
        errorMessage = nil
        do {
            let (data, response) = try await URLSession.shared.data(from: jsonURL)
            var module: ModuleDefinition
            if let seanime = SeanimeManifest.detect(data) {
                // A Seanime provider's manifest: its script is fetched, converted and checked here.
                module = try await SeanimeInstaller.module(from: seanime, manifestURL: jsonURL)
                await cacheIcon(for: &module)
            } else {
                do {
                    module = try JSONDecoder().decode(ModuleDefinition.self, from: data)
                } catch {
                    // Not a module: say what the link is instead.
                    throw ModuleLinkError.diagnose(data, response: response, url: jsonURL)
                }
                module.jsonUrl = jsonURL.absoluteString
                // Cache script and icon
                await cacheAssets(for: &module)
            }

            if isAdult(module) { throw ModuleLinkError.adult }

            // Avoid duplicates
            if modules.contains(where: { $0.id == module.id }) {
                modules.removeAll { $0.id == module.id }
            }
            modules.append(module)
            saveToStorage()

            // Auto-select if it's the first module
            if activeModule == nil {
                selectModule(module)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Adult modules installed before Shirox refused them. Run once the host list has loaded,
    /// so the sites they reach are checked too.
    func removeAdultModules() {
        for module in modules where isAdult(module) {
            Logger.shared.log("[ModuleManager] Removed adult module \(module.sourceName)", type: "Info")
            removeModule(module)
        }
    }

    private func isAdult(_ module: ModuleDefinition) -> Bool {
        AdultModuleCheck.isAdult(module) { HostBlocklist.shared.isBlocked(host: $0) }
    }

    // MARK: - Remove Module

    func removeModule(_ module: ModuleDefinition) {
        modules.removeAll { $0.id == module.id }
        if activeModule?.id == module.id {
            activeModule = nil
        }
        saveToStorage()
    }

    // MARK: - Select Module

    func selectModule(_ module: ModuleDefinition) {
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
        
        Task {
            do {
                try await JSEngine.shared.loadModule(module)
                moduleReadyId = module.id
            } catch {
                Logger.shared.log("[ModuleManager] Failed to load JS for module \(module.sourceName): \(error.localizedDescription)", type: "Error")
            }
        }
    }

    /// Like selectModule, but suspends until the module's JS is loaded.
    /// Returns false when the script failed to load. Used by flows that must
    /// call into the module immediately after switching (Continue Reading).
    func selectAndAwaitReady(_ module: ModuleDefinition) async -> Bool {
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
        do {
            try await JSEngine.shared.loadModule(module)
            moduleReadyId = module.id
            return true
        } catch {
            Logger.shared.log("[ModuleManager] Failed to load JS for module \(module.sourceName): \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    // MARK: - Reorder Modules

    func moveModules(from source: IndexSet, to destination: Int) {
        modules.move(fromOffsets: source, toOffset: destination)
        saveToStorage()
    }

    func deselectModule() {
        activeModule = nil
        UserDefaults.standard.removeObject(forKey: activeKey)
    }

    // MARK: - Restore Active Module on Launch

    func restoreActiveModule() async {
        guard let savedId = UserDefaults.standard.string(forKey: activeKey),
              let module = modules.first(where: { $0.id == savedId }) else { return }
        selectModule(module)
    }

    // MARK: - Backup Restore

    /// Replaces the installed module list from a backup by re-fetching each manifest.
    /// Returns the `jsonUrl`s that could not be installed, so the import can report them.
    ///
    /// Re-fetching rather than restoring stored definitions keeps the backup file small:
    /// a `ModuleDefinition` carries the module's whole script in `scriptContent` and its
    /// icon as base64 in `iconData`.
    func restoreModules(jsonUrls: [String], activeId: String?) async -> [String] {
        modules = []
        activeModule = nil
        saveToStorage()

        var failed: [String] = []
        for urlString in jsonUrls {
            guard let url = URL(string: urlString) else {
                failed.append(urlString)
                continue
            }
            let before = modules.count
            await addModule(from: url)
            if modules.count == before { failed.append(urlString) }
        }

        if let activeId, let module = modules.first(where: { $0.id == activeId }) {
            selectModule(module)
        }
        return failed
    }

    // MARK: - Auto-Update

    func checkForUpdates() async {
        var didUpdate = false
        for i in modules.indices {
            guard let jsonUrlStr = modules[i].jsonUrl,
                  let jsonURL = URL(string: jsonUrlStr),
                  let (data, _) = try? await URLSession.shared.data(from: jsonURL) else { continue }
            var fresh: ModuleDefinition
            if let seanime = SeanimeManifest.detect(data) {
                guard seanime.version != modules[i].version,
                      let installed = try? await SeanimeInstaller.module(from: seanime, manifestURL: jsonURL) else { continue }
                fresh = installed
                await cacheIcon(for: &fresh)
            } else {
                guard let decoded = try? JSONDecoder().decode(ModuleDefinition.self, from: data),
                      decoded.version != modules[i].version else { continue }
                fresh = decoded
                fresh.jsonUrl = jsonUrlStr
                // Cache fresh assets
                await cacheAssets(for: &fresh)
            }
            // An update that turns a module adult isn't taken.
            guard !isAdult(fresh) else { continue }

            let wasActive = activeModule?.id == modules[i].id
            modules[i] = fresh
            if wasActive { selectModule(fresh) }
            didUpdate = true
        }
        if didUpdate { saveToStorage() }
    }

    // MARK: - Asset Caching

    private func cacheAssets(for module: inout ModuleDefinition) async {
        await cacheScript(for: &module)
        await cacheIcon(for: &module)
    }

    private func cacheScript(for module: inout ModuleDefinition) async {
        if let scriptURL = URL(string: module.scriptUrl),
           let (data, _) = try? await URLSession.shared.data(from: scriptURL),
           let script = String(data: data, encoding: .utf8) {
            module.scriptContent = script
        }
    }

    private func cacheIcon(for module: inout ModuleDefinition) async {
        if let iconUrlStr = module.iconUrl,
           let iconURL = URL(string: iconUrlStr),
           let (data, _) = try? await URLSession.shared.data(from: iconURL) {
            module.iconData = data.base64EncodedString()
        }
    }

    // MARK: - Persistence

    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(modules) {
            storage.save(data)
        }
    }

    private func loadFromStorage() {
        guard let data = storage.load(),
              let saved = try? JSONDecoder().decode([ModuleDefinition].self, from: data) else { return }
        modules = saved
    }
}
