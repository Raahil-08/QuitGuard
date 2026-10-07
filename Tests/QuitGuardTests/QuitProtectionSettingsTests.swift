import XCTest

final class QuitProtectionSettingsTests: XCTestCase {

    private var suites: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "com.raahil.quitguard.tests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suites.removeAll()
        super.tearDown()
    }

    func testFreshInstallIsOff() {
        XCTAssertFalse(QuitProtectionSettings(defaults: makeDefaults()).isEnabled)
    }

    func testExistingInstallWithTickedAppsMigratesToOn() {
        let defaults = makeDefaults()
        defaults.set(["com.example.app"], forKey: ProtectedAppsStore.defaultsKey)
        XCTAssertTrue(QuitProtectionSettings(defaults: defaults).isEnabled)
    }

    func testExplicitOffBeatsTickedApps() {
        let defaults = makeDefaults()
        defaults.set(["com.example.app"], forKey: ProtectedAppsStore.defaultsKey)
        defaults.set(false, forKey: QuitProtectionSettings.defaultsKey)
        XCTAssertFalse(QuitProtectionSettings(defaults: defaults).isEnabled)
    }

    func testInitialValueTruthTable() {
        XCTAssertFalse(QuitProtectionSettings.initialValue(stored: nil, hasProtectedApps: false))
        XCTAssertTrue(QuitProtectionSettings.initialValue(stored: nil, hasProtectedApps: true))
        XCTAssertTrue(QuitProtectionSettings.initialValue(stored: true, hasProtectedApps: false))
        XCTAssertFalse(QuitProtectionSettings.initialValue(stored: false, hasProtectedApps: true))
    }

    func testSetEnabledPersistsAndReloadPicksUpTerminalWrite() {
        let defaults = makeDefaults()
        let settings = QuitProtectionSettings(defaults: defaults)

        settings.setEnabled(true)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(defaults.object(forKey: QuitProtectionSettings.defaultsKey) as? Bool, true)

        // Simulates `defaults write` from a terminal, which sends no notification.
        defaults.set(false, forKey: QuitProtectionSettings.defaultsKey)
        settings.reload()
        XCTAssertFalse(settings.isEnabled)
    }
}
