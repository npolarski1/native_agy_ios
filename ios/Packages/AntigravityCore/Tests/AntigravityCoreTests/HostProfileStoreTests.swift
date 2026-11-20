import Foundation
import XCTest
import AntigravityCore

final class HostProfileStoreTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var tokenStore: InMemoryTokenStore!
    private var store: HostProfileStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.antigravity.tests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        tokenStore = InMemoryTokenStore()
        store = HostProfileStore(userDefaults: userDefaults, tokenStore: tokenStore)
    }

    override func tearDown() {
        if let suiteName {
            userDefaults?.removePersistentDomain(forName: suiteName)
        }
        store = nil
        tokenStore = nil
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testUpsertFirstHostSetsActiveAndStoresTokenSeparately() throws {
        let url = try PairingURI.normalizeBaseURL("http://192.168.1.20:8765/")
        let profile = try store.upsertHost(name: "Main Workstation", baseURL: url, token: "tok-primary")

        XCTAssertEqual(store.loadProfiles().count, 1)
        XCTAssertEqual(store.activeHostID(), profile.id)
        XCTAssertEqual(store.activeProfile(), profile)
        XCTAssertEqual(try store.activeToken(), "tok-primary")
        XCTAssertEqual(try store.token(for: profile.id), "tok-primary")

        // Verify token is NOT persisted in plain UserDefaults metadata.
        if let rawData = userDefaults.data(forKey: HostProfileStore.profilesStorageKey),
           let rawText = String(data: rawData, encoding: .utf8) {
            XCTAssertFalse(rawText.contains("tok-primary"))
        } else {
            XCTFail("Expected encoded profiles in UserDefaults")
        }
    }

    func testUpsertDeduplicatesByNormalizedBaseURL() throws {
        let first = try store.upsertHost(
            name: "Box Old",
            baseURL: URL(string: "http://192.168.1.50:8765/")!,
            token: "token-v1"
        )
        let second = try store.upsertHost(
            name: "Box Renamed",
            baseURL: URL(string: "HTTP://192.168.1.50:8765")!,
            token: "token-v2"
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.loadProfiles().count, 1)
        XCTAssertEqual(store.activeProfile()?.name, "Box Renamed")
        XCTAssertEqual(try store.activeToken(), "token-v2")
    }

    func testMultiHostSelectionAndActiveFallbackOnDelete() throws {
        let hostA = try store.upsertHost(
            name: "Host A",
            baseURL: URL(string: "http://10.0.0.1:8765")!,
            token: "tok-a",
            makeActive: true
        )
        let hostB = try store.upsertHost(
            name: "Host B",
            baseURL: URL(string: "http://10.0.0.2:8765")!,
            token: "tok-b",
            makeActive: false
        )

        XCTAssertEqual(store.loadProfiles().count, 2)
        XCTAssertEqual(store.activeHostID(), hostA.id)

        store.setActiveHost(id: hostB.id)
        XCTAssertEqual(store.activeHostID(), hostB.id)
        XCTAssertEqual(try store.activeToken(), "tok-b")

        try store.removeHost(id: hostB.id)
        XCTAssertEqual(store.loadProfiles().count, 1)
        XCTAssertNil(try tokenStore.loadToken(for: hostB.id))
        XCTAssertEqual(store.activeHostID(), hostA.id)
        XCTAssertEqual(try store.activeToken(), "tok-a")

        try store.removeHost(id: hostA.id)
        XCTAssertTrue(store.loadProfiles().isEmpty)
        XCTAssertNil(store.activeProfile())
        XCTAssertNil(try store.activeToken())
    }

    func testUpsertFromPairingPayloadAndUpdateLastConnected() throws {
        let payload = try PairingURI.parse(
            "agymon://pair?url=https%3A%2F%2Fmac.ts.net&token=ts-token&name=Tailscale%20Mac"
        )
        let profile = try store.upsertHost(from: payload)
        XCTAssertEqual(profile.name, "Tailscale Mac")
        XCTAssertNil(profile.lastConnectedAt)

        let timestamp = Date(timeIntervalSince1970: 1_795_000_000)
        store.updateLastConnected(for: profile.id, at: timestamp)

        let reloaded = try XCTUnwrap(store.activeProfile())
        XCTAssertEqual(reloaded.lastConnectedAt?.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 1.0)
    }

    func testWidgetStatusSnapshotRoundtrip() throws {
        XCTAssertNil(store.loadWidgetSnapshot())

        let snapshot = DemoDataProvider.sampleWidgetSnapshot(now: Date(timeIntervalSince1970: 1_795_000_000))
        store.saveWidgetSnapshot(snapshot)

        let loaded = try XCTUnwrap(store.loadWidgetSnapshot())
        XCTAssertEqual(loaded.hostName, snapshot.hostName)
        XCTAssertEqual(loaded.activeSessionCount, snapshot.activeSessionCount)
        XCTAssertEqual(loaded.pendingApprovalCount, snapshot.pendingApprovalCount)
        XCTAssertEqual(loaded.activeSessionTitle, snapshot.activeSessionTitle)
        XCTAssertEqual(loaded.activeSessionStatus, snapshot.activeSessionStatus)
        XCTAssertEqual(loaded.totalTokens, snapshot.totalTokens)
        XCTAssertEqual(loaded.cacheHitRate, snapshot.cacheHitRate, accuracy: 0.0001)
    }
}
