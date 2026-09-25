import Foundation
import Combine

/// Where Home and Search come from: the AniList/MyAnimeList chain, or Simkl.
///
/// Simkl is kept out of `ProviderManager`'s chain — its ids aren't AniList's or MyAnimeList's —
/// so anime pages, tracking, profile and notifications carry on from the chain whichever is
/// chosen here.
@MainActor
final class DiscoverySource: ObservableObject {
    static let shared = DiscoverySource()

    // Nonisolated: the settings backup lists them outside the main actor.
    nonisolated static let choiceKey = "discoverySource"
    nonisolated static let kindKey = "simklDiscoverKind"

    enum Choice: String { case providers, simkl }

    @Published private(set) var choice: Choice
    /// Home's and Search's Anime / Shows / Movies pills.
    @Published var simklKind: MediaKind {
        didSet { defaults.set(simklKind.rawValue, forKey: Self.kindKey) }
    }
    /// Simkl chosen, and signed in to it. Signing out falls back to the chain by itself.
    @Published private(set) var usesSimkl = false

    private let defaults: UserDefaults
    private let selectProvider: @MainActor (ProviderType) -> Void
    private var signedIn = false
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard,
         signedIn: AnyPublisher<Bool, Never>? = nil,
         selectProvider: @escaping @MainActor (ProviderType) -> Void = { ProviderManager.shared.selectProvider($0) }) {
        self.defaults = defaults
        self.selectProvider = selectProvider
        choice = Choice(rawValue: defaults.string(forKey: Self.choiceKey) ?? "") ?? .providers
        let stored = MediaKind(rawValue: defaults.string(forKey: Self.kindKey) ?? "")
        simklKind = stored.flatMap { MediaKind.simklKinds.contains($0) ? $0 : nil } ?? .anime
        (signedIn ?? SimklAuthManager.shared.$isLoggedIn.eraseToAnyPublisher())
            .sink { [weak self] value in
                self?.signedIn = value
                self?.update()
            }
            .store(in: &cancellables)
    }

    func chooseSimkl() {
        set(.simkl)
    }

    /// Back to the chain, with `type` first in it.
    func chooseProvider(_ type: ProviderType) {
        set(.providers)
        selectProvider(type)
    }

    private func set(_ new: Choice) {
        choice = new
        defaults.set(new.rawValue, forKey: Self.choiceKey)
        update()
    }

    private func update() {
        let value = choice == .simkl && signedIn
        if usesSimkl != value { usesSimkl = value }
    }
}
