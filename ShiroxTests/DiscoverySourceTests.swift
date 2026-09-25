import XCTest
import Combine
@testable import Shirox

/// Where Home and Search come from: the AniList/MAL chain, or Simkl while signed in to it.
@MainActor
final class DiscoverySourceTests: XCTestCase {
    private let signedIn = CurrentValueSubject<Bool, Never>(true)
    private var selected: [ProviderType] = []
    private lazy var defaults: UserDefaults = {
        let name = "DiscoverySourceTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }()

    private func source() -> DiscoverySource {
        DiscoverySource(defaults: defaults, signedIn: signedIn.eraseToAnyPublisher(),
                        selectProvider: { [unowned self] in self.selected.append($0) })
    }

    func testTheChainIsTheDefault() {
        let source = source()
        XCTAssertEqual(source.choice, .providers)
        XCTAssertFalse(source.usesSimkl)
        XCTAssertEqual(source.simklKind, .anime)
    }

    func testSimklIsUsedOnlyWhileSignedIn() {
        let source = source()
        source.chooseSimkl()
        XCTAssertTrue(source.usesSimkl)
        signedIn.send(false)
        XCTAssertFalse(source.usesSimkl, "Signing out falls back to the chain")
        signedIn.send(true)
        XCTAssertTrue(source.usesSimkl)
    }

    func testChoosingAProviderGoesBackToTheChain() {
        let source = source()
        source.chooseSimkl()
        source.chooseProvider(.mal)
        XCTAssertFalse(source.usesSimkl)
        XCTAssertEqual(source.choice, .providers)
        XCTAssertEqual(selected, [.mal])
    }

    func testTheChoiceAndKindAreRemembered() {
        let first = source()
        first.chooseSimkl()
        first.simklKind = .movie
        let again = source()
        XCTAssertTrue(again.usesSimkl)
        XCTAssertEqual(again.simklKind, .movie)
    }

    func testAStoredKindSimklDoesntHaveIsAnime() {
        defaults.set("manga", forKey: DiscoverySource.kindKey)
        XCTAssertEqual(source().simklKind, .anime)
    }

    func testBothSettingsAreBackedUp() {
        XCTAssertTrue(SettingsBackupSection.stringKeys.contains(DiscoverySource.choiceKey))
        XCTAssertTrue(SettingsBackupSection.stringKeys.contains(DiscoverySource.kindKey))
    }
}
