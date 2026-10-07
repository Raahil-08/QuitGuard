import XCTest

@MainActor
final class FeatureCatalogTests: XCTestCase {

    func testEveryFeatureHasCopy() {
        for feature in Feature.allCases {
            XCTAssertFalse(feature.title.isEmpty)
            XCTAssertFalse(feature.summary.isEmpty)
            XCTAssertFalse(feature.systemImage.isEmpty)
        }
        for idea in FeatureIdea.allCases {
            XCTAssertFalse(idea.title.isEmpty)
            XCTAssertFalse(idea.summary.isEmpty)
        }
    }

    func testStayAwakeIsTheOnlyAdminPasswordFeature() {
        XCTAssertEqual(Feature.allCases.filter(\.needsAdminPassword), [.stayAwake])
        XCTAssertEqual(Feature.stayAwake.requirementNote, "Asks for admin password")
        XCTAssertEqual(Feature.quitProtection.requirementNote, "Needs Accessibility")
    }

    func testWishlistPersists() {
        let name = "com.raahil.quitguard.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }

        let list = FeatureWishlist(defaults: defaults)
        XCTAssertFalse(list.isWanted(.holdToQuit))
        list.setWanted(true, for: .holdToQuit)
        XCTAssertTrue(FeatureWishlist(defaults: defaults).isWanted(.holdToQuit))
        list.setWanted(false, for: .holdToQuit)
        XCTAssertFalse(FeatureWishlist(defaults: defaults).isWanted(.holdToQuit))
    }
}
