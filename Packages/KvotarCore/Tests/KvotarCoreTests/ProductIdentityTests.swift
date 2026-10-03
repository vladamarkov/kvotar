import XCTest
@testable import KvotarCore

final class ProductIdentityTests: XCTestCase {
    func testShippedIdentityIsPermanentKvotarIdentity() {
        XCTAssertEqual(ProductIdentity.productName, "Kvotar")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "com.vladimirmarkovic.kvotar")
        XCTAssertEqual(ProductIdentity.applicationSupportDirectoryName, "Kvotar")
        XCTAssertEqual(ProductIdentity.databaseFilename, "kvotar.db")
        XCTAssertEqual(ProductIdentity.pidFilename, "kvotar.pid")
        XCTAssertEqual(ProductIdentity.logDirectoryName, "Kvotar")
        XCTAssertEqual(ProductIdentity.logBasename, "kvotar")
        XCTAssertEqual(ProductIdentity.buildChannelInfoKey, "KvotarChannel")
        XCTAssertEqual(ProductIdentity.buildChannelSetting, "KVOTAR_CHANNEL")
    }

    func testLegacyIdentityIsIsolatedForMigrationAndCompatibility() {
        XCTAssertEqual(ProductIdentity.Legacy.productName, "AgentPilot")
        XCTAssertEqual(ProductIdentity.Legacy.bundleIdentifier, "com.agentpilot.app")
        XCTAssertEqual(ProductIdentity.Legacy.applicationSupportDirectoryName, "AgentPilot")
        XCTAssertEqual(ProductIdentity.Legacy.databaseFilename, "agentpilot.db")
        XCTAssertEqual(ProductIdentity.Legacy.pidFilename, "agentpilot.pid")
        XCTAssertNotEqual(ProductIdentity.bundleIdentifier, ProductIdentity.Legacy.bundleIdentifier)
    }
}
