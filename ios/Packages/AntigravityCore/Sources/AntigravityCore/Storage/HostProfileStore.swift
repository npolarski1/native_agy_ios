import Foundation

public final class HostProfileStore: @unchecked Sendable {
    public static let defaultAppGroupIdentifier = "group.com.antigravity.monitor"
    public static let profilesStorageKey = "antigravity.hostProfiles.v1"
    public static let activeHostIDStorageKey = "antigravity.activeHostID.v1"
    public static let widgetSnapshotStorageKey = "antigravity.widgetSnapshot.v1"

    private let userDefaults: UserDefaults
    private let tokenStore: any TokenStoreProtocol
    private let lock = NSLock()

    public init(userDefaults: UserDefaults, tokenStore: any TokenStoreProtocol) {
        self.userDefaults = userDefaults
        self.tokenStore = tokenStore
    }

    public convenience init(
        appGroupIdentifier: String? = HostProfileStore.defaultAppGroupIdentifier,
        tokenStore: (any TokenStoreProtocol)? = nil
    ) {
        let defaults: UserDefaults
        if let suite = appGroupIdentifier, !suite.isEmpty, let suiteDefaults = UserDefaults(suiteName: suite) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }

        let resolvedTokenStore: any TokenStoreProtocol
        if let tokenStore {
            resolvedTokenStore = tokenStore
        } else {
            #if canImport(Security)
            resolvedTokenStore = KeychainTokenStore()
            #else
            resolvedTokenStore = InMemoryTokenStore()
            #endif
        }

        self.init(userDefaults: defaults, tokenStore: resolvedTokenStore)
    }

    // MARK: - Profiles

    public func loadProfiles() -> [HostProfile] {
        lock.lock()
        defer { lock.unlock() }
        return lockedLoadProfiles()
    }

    public func activeHostID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return lockedActiveHostID()
    }

    public func activeProfile() -> HostProfile? {
        lock.lock()
        defer { lock.unlock() }
        let profiles = lockedLoadProfiles()
        if let activeID = lockedActiveHostID(),
           let match = profiles.first(where: { $0.id == activeID }) {
            return match
        }
        return profiles.first
    }

    public func token(for hostId: UUID) throws -> String? {
        try tokenStore.loadToken(for: hostId)
    }

    public func activeToken() throws -> String? {
        guard let profile = activeProfile() else { return nil }
        return try tokenStore.loadToken(for: profile.id)
    }

    @discardableResult
    public func upsertHost(
        name: String,
        baseURL: URL,
        token: String,
        makeActive: Bool = true
    ) throws -> HostProfile {
        let normalizedURL = (try? PairingURI.normalizeBaseURL(baseURL.absoluteString)) ?? baseURL
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? (normalizedURL.host ?? "Antigravity Host") : trimmedName

        lock.lock()
        var profiles = lockedLoadProfiles()
        let normalizedKey = normalizedURL.absoluteString.lowercased()

        let resultProfile: HostProfile
        if let existingIndex = profiles.firstIndex(where: { $0.normalizedBaseURLKey == normalizedKey }) {
            let existing = profiles[existingIndex]
            let updated = HostProfile(
                id: existing.id,
                name: resolvedName,
                baseURL: normalizedURL,
                createdAt: Self.normalizedTimestamp(existing.createdAt),
                lastConnectedAt: existing.lastConnectedAt.map(Self.normalizedTimestamp)
            )
            profiles[existingIndex] = updated
            resultProfile = updated
        } else {
            let created = HostProfile(
                name: resolvedName,
                baseURL: normalizedURL,
                createdAt: Self.normalizedTimestamp(Date())
            )
            profiles.append(created)
            resultProfile = created
        }

        let shouldSetActive = makeActive || lockedActiveHostID() == nil || profiles.count == 1
        lock.unlock()

        try tokenStore.saveToken(token, for: resultProfile.id)

        lock.lock()
        lockedSaveProfiles(profiles)
        if shouldSetActive {
            lockedSetActiveHostID(resultProfile.id)
        }
        lock.unlock()

        return resultProfile
    }

    @discardableResult
    public func upsertHost(from pairing: PairingPayload, makeActive: Bool = true) throws -> HostProfile {
        try upsertHost(
            name: pairing.name,
            baseURL: pairing.baseURL,
            token: pairing.token,
            makeActive: makeActive
        )
    }

    public func saveProfile(_ profile: HostProfile, token: String, makeActive: Bool = false) throws {
        try tokenStore.saveToken(token, for: profile.id)

        let normalized = HostProfile(
            id: profile.id,
            name: profile.name,
            baseURL: profile.baseURL,
            createdAt: Self.normalizedTimestamp(profile.createdAt),
            lastConnectedAt: profile.lastConnectedAt.map(Self.normalizedTimestamp)
        )

        lock.lock()
        defer { lock.unlock() }
        var profiles = lockedLoadProfiles()
        if let idx = profiles.firstIndex(where: { $0.id == normalized.id }) {
            profiles[idx] = normalized
        } else {
            profiles.append(normalized)
        }
        lockedSaveProfiles(profiles)
        if makeActive || lockedActiveHostID() == nil {
            lockedSetActiveHostID(normalized.id)
        }
    }

    public func updateLastConnected(for hostId: UUID, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var profiles = lockedLoadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == hostId }) else { return }
        profiles[index].lastConnectedAt = Self.normalizedTimestamp(date)
        lockedSaveProfiles(profiles)
    }

    public func setActiveHost(id: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        guard let id else {
            lockedSetActiveHostID(nil)
            return
        }
        let profiles = lockedLoadProfiles()
        if profiles.contains(where: { $0.id == id }) {
            lockedSetActiveHostID(id)
        }
    }

    public func removeHost(id: UUID) throws {
        try tokenStore.deleteToken(for: id)

        lock.lock()
        defer { lock.unlock() }
        var profiles = lockedLoadProfiles()
        profiles.removeAll { $0.id == id }
        lockedSaveProfiles(profiles)

        if lockedActiveHostID() == id {
            lockedSetActiveHostID(profiles.first?.id)
        }
    }

    public func clearAll() throws {
        lock.lock()
        let profiles = lockedLoadProfiles()
        lock.unlock()

        for profile in profiles {
            try tokenStore.deleteToken(for: profile.id)
        }

        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: Self.profilesStorageKey)
        userDefaults.removeObject(forKey: Self.activeHostIDStorageKey)
    }

    // MARK: - WidgetKit Shared Snapshot

    public func saveWidgetSnapshot(_ snapshot: WidgetStatusSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? BridgeJSONEncoder.encode(snapshot) else { return }
        userDefaults.set(data, forKey: Self.widgetSnapshotStorageKey)
    }

    public func loadWidgetSnapshot() -> WidgetStatusSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = userDefaults.data(forKey: Self.widgetSnapshotStorageKey) else {
            return nil
        }
        return try? BridgeJSONDecoder.decode(WidgetStatusSnapshot.self, from: data)
    }

    // MARK: - Private Locked Helpers

    private func lockedLoadProfiles() -> [HostProfile] {
        guard let data = userDefaults.data(forKey: Self.profilesStorageKey) else {
            return []
        }
        return (try? BridgeJSONDecoder.decode([HostProfile].self, from: data)) ?? []
    }

    private func lockedSaveProfiles(_ profiles: [HostProfile]) {
        guard let data = try? BridgeJSONEncoder.encode(profiles) else { return }
        userDefaults.set(data, forKey: Self.profilesStorageKey)
    }

    private func lockedActiveHostID() -> UUID? {
        guard let raw = userDefaults.string(forKey: Self.activeHostIDStorageKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func lockedSetActiveHostID(_ id: UUID?) {
        if let id {
            userDefaults.set(id.uuidString, forKey: Self.activeHostIDStorageKey)
        } else {
            userDefaults.removeObject(forKey: Self.activeHostIDStorageKey)
        }
    }

    private static func normalizedTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
