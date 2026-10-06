import XCTest

final class ProtectedAppsStoreTests: XCTestCase {

    private var suite = ""

    private func makeDefaults() -> UserDefaults {
        suite = "com.raahil.quitguard.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertTrue(ProtectedAppsStore(defaults: makeDefaults()).all.isEmpty)
    }

    func testSetProtectedAddsAndRemoves() {
        let store = ProtectedAppsStore(defaults: makeDefaults())
        store.setProtected(true, for: "com.example.a")
        XCTAssertTrue(store.contains("com.example.a"))
        store.setProtected(false, for: "com.example.a")
        XCTAssertFalse(store.contains("com.example.a"))
    }

    func testPersistsAcrossInstances() {
        let defaults = makeDefaults()
        ProtectedAppsStore(defaults: defaults).setProtected(true, for: "com.example.a")
        XCTAssertTrue(ProtectedAppsStore(defaults: defaults).contains("com.example.a"))
    }

    func testReloadPicksUpTerminalWrite() {
        let defaults = makeDefaults()
        let store = ProtectedAppsStore(defaults: defaults)
        defaults.set(["com.example.b"], forKey: ProtectedAppsStore.defaultsKey)
        store.reload()
        XCTAssertEqual(store.all, ["com.example.b"])
    }
}
