import XCTest
@testable import Shirox

/// Bytes kept in a file of their own rather than in UserDefaults, moved over from UserDefaults
/// once, and kept there still if the file can't be written.
final class StoredFileTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stored-\(UUID().uuidString)")
        suite = "stored-file-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func file(_ legacyKey: String? = "old", in directory: URL? = nil) -> StoredFile {
        StoredFile(name: "thing.json", legacyKey: legacyKey, directory: directory ?? self.directory, defaults: defaults)
    }

    func testWhatsSavedLoadsBack() {
        file().save(Data("hello".utf8))
        XCTAssertEqual(file().load(), Data("hello".utf8))
    }

    func testNothingSavedLoadsNothing() {
        XCTAssertNil(file().load())
    }

    func testBytesInUserDefaultsMoveToTheFile() {
        defaults.set(Data("modules".utf8), forKey: "old")
        XCTAssertEqual(file().load(), Data("modules".utf8))
        XCTAssertNil(defaults.object(forKey: "old"), "left behind in UserDefaults")
        XCTAssertEqual(try? Data(contentsOf: file().url), Data("modules".utf8))
    }

    /// The ID mappings were a dictionary in UserDefaults, not bytes.
    func testADictionaryInUserDefaultsMovesOverAsJSON() throws {
        defaults.set(["anilist-1": 5, "mal-5": 1], forKey: "old")
        let data = try XCTUnwrap(file().load())
        XCTAssertEqual(try JSONDecoder().decode([String: Int].self, from: data), ["anilist-1": 5, "mal-5": 1])
        XCTAssertNil(defaults.object(forKey: "old"))
    }

    /// A full disk mustn't lose what's being saved: it stays in UserDefaults, as it always was.
    func testWhatCantBeWrittenStaysInUserDefaults() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: blocker)
        let unwritable = file(in: blocker)
        unwritable.save(Data("kept".utf8))
        XCTAssertEqual(defaults.data(forKey: "old"), Data("kept".utf8))
        XCTAssertEqual(unwritable.load(), Data("kept".utf8))
    }

    /// Once the file can be written again, UserDefaults' copy goes, so the two never disagree.
    func testSavingToTheFileDropsTheUserDefaultsCopy() {
        defaults.set(Data("stale".utf8), forKey: "old")
        file().save(Data("fresh".utf8))
        XCTAssertNil(defaults.object(forKey: "old"))
        XCTAssertEqual(file().load(), Data("fresh".utf8))
    }

    func testRemoveClearsBoth() {
        file().save(Data("a".utf8))
        defaults.set(Data("b".utf8), forKey: "old")
        file().remove()
        XCTAssertNil(file().load())
    }
}
