import Foundation
import Observation
#if canImport(Network)
import Network
#endif

public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let domain: String
    public let host: String?
    public let port: Int?
    public let txtRecord: [String: String]

    public init(
        id: String? = nil,
        name: String,
        type: String = BonjourDiscovery.serviceType,
        domain: String = BonjourDiscovery.defaultDomain,
        host: String? = nil,
        port: Int? = nil,
        txtRecord: [String: String] = [:]
    ) {
        self.id = id ?? "\(name).\(type).\(domain)"
        self.name = name
        self.type = type
        self.domain = domain
        self.host = host
        self.port = port
        self.txtRecord = txtRecord
    }

    public var suggestedURL: URL? {
        if let rawURL = txtRecord["url"],
           let normalized = try? PairingURI.normalizeBaseURL(rawURL) {
            return normalized
        }

        let resolvedHost = (host ?? txtRecord["host"] ?? txtRecord["hostname"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedHost, !resolvedHost.isEmpty else {
            return nil
        }

        let resolvedPort = port ?? txtRecord["port"].flatMap(Int.init) ?? 8765
        let scheme = (txtRecord["scheme"]?.lowercased() == "https") ? "https" : "http"
        let hostPart: String
        if resolvedHost.contains(":") && !resolvedHost.hasPrefix("[") {
            hostPart = "[\(resolvedHost)]"
        } else {
            hostPart = resolvedHost
        }

        return try? PairingURI.normalizeBaseURL("\(scheme)://\(hostPart):\(resolvedPort)")
    }
}

@MainActor
@Observable
public final class BonjourDiscovery {
    public nonisolated static let serviceType = "_antigravity-mon._tcp"
    public nonisolated static let defaultDomain = "local."

    public let serviceType: String
    public let domain: String

    public private(set) var hosts: [DiscoveredHost] = []
    public private(set) var isSearching: Bool = false
    public private(set) var lastError: String?

    #if canImport(Network)
    @ObservationIgnored
    private let browserBox = BrowserBox()

    @ObservationIgnored
    private let queue = DispatchQueue(label: "com.antigravity.bonjour.discovery", qos: .userInitiated)
    #endif

    public init(
        serviceType: String = BonjourDiscovery.serviceType,
        domain: String = BonjourDiscovery.defaultDomain
    ) {
        self.serviceType = serviceType
        self.domain = domain
    }

    deinit {
        #if canImport(Network)
        browserBox.cancel()
        #endif
    }

    public func start() {
        #if canImport(Network)
        stop()

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: serviceType,
            domain: domain
        )
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            let searching: Bool
            let errorMessage: String?
            switch state {
            case .setup, .ready:
                searching = true
                errorMessage = nil
            case .waiting(let error):
                searching = true
                errorMessage = error.localizedDescription
            case .failed(let error):
                searching = false
                errorMessage = error.localizedDescription
            case .cancelled:
                searching = false
                errorMessage = nil
            @unknown default:
                searching = false
                errorMessage = nil
            }

            Task { @MainActor [weak self] in
                self?.isSearching = searching
                self?.lastError = errorMessage
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed = Self.parseResults(results)
            Task { @MainActor [weak self] in
                self?.mergeDiscoveredHosts(parsed)
            }
        }

        browserBox.set(browser)
        isSearching = true
        lastError = nil
        browser.start(queue: queue)
        #else
        isSearching = false
        lastError = "Bonjour discovery is unavailable on this platform."
        #endif
    }

    public func stop() {
        #if canImport(Network)
        browserBox.cancel()
        #endif
        isSearching = false
    }

    public func resolve(_ discovered: DiscoveredHost, timeoutSeconds: TimeInterval = 3.0) async -> DiscoveredHost {
        if discovered.host != nil && discovered.port != nil {
            return discovered
        }

        #if canImport(Network)
        let resolveQueue = self.queue
        let resolved: DiscoveredHost = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let endpoint = NWEndpoint.service(
                name: discovered.name,
                type: discovered.type,
                domain: discovered.domain,
                interface: nil
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            let connectionRef = ConnectionBox(connection)

            let finish: @Sendable (DiscoveredHost) -> Void = { result in
                guard once.claim() else { return }
                connectionRef.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let remoteEndpoint = connectionRef.remoteEndpoint(),
                       case .hostPort(let nwHost, let nwPort) = remoteEndpoint {
                        let hostString = Self.extractHostString(nwHost)
                        let portInt = Int(nwPort.rawValue)
                        let updated = DiscoveredHost(
                            id: discovered.id,
                            name: discovered.name,
                            type: discovered.type,
                            domain: discovered.domain,
                            host: hostString ?? discovered.host,
                            port: portInt,
                            txtRecord: discovered.txtRecord
                        )
                        finish(updated)
                    } else {
                        finish(discovered)
                    }
                case .failed, .cancelled:
                    finish(discovered)
                default:
                    break
                }
            }

            connection.start(queue: resolveQueue)
            resolveQueue.asyncAfter(deadline: .now() + max(0.5, timeoutSeconds)) {
                finish(discovered)
            }
        }

        if let index = hosts.firstIndex(where: { $0.id == resolved.id }) {
            hosts[index] = resolved
        }
        return resolved
        #else
        return discovered
        #endif
    }

    // MARK: - Private Helpers

    private func mergeDiscoveredHosts(_ discovered: [DiscoveredHost]) {
        let existingByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let merged = discovered.map { item -> DiscoveredHost in
            if item.host == nil || item.port == nil, let prev = existingByID[item.id] {
                return DiscoveredHost(
                    id: item.id,
                    name: item.name,
                    type: item.type,
                    domain: item.domain,
                    host: item.host ?? prev.host,
                    port: item.port ?? prev.port,
                    txtRecord: item.txtRecord.isEmpty ? prev.txtRecord : item.txtRecord
                )
            }
            return item
        }
        hosts = merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    #if canImport(Network)
    private nonisolated static func parseResults(_ results: Set<NWBrowser.Result>) -> [DiscoveredHost] {
        var parsed: [DiscoveredHost] = []
        parsed.reserveCapacity(results.count)

        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                continue
            }

            var txtDict: [String: String] = [:]
            if case .bonjour(let txtRecord) = result.metadata {
                txtDict = txtRecord.dictionary
            }

            let host = (txtDict["host"] ?? txtDict["hostname"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = txtDict["port"].flatMap(Int.init)

            parsed.append(
                DiscoveredHost(
                    name: name,
                    type: type,
                    domain: domain,
                    host: (host?.isEmpty == false) ? host : nil,
                    port: port,
                    txtRecord: txtDict
                )
            )
        }
        return parsed
    }

    private nonisolated static func extractHostString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .name(let hostname, _):
            let trimmed = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
            return trimmed.isEmpty ? nil : trimmed
        case .ipv4(let ipv4):
            let bytes = Array(ipv4.rawValue)
            if bytes.count == 4 {
                return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
            }
            return ipv4.debugDescription
        case .ipv6(let ipv6):
            let raw = ipv6.debugDescription
            if let percentIdx = raw.firstIndex(of: "%") {
                return String(raw[..<percentIdx])
            }
            return raw
        @unknown default:
            return nil
        }
    }
    #endif
}

#if canImport(Network)
private final class BrowserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var browser: NWBrowser?

    func set(_ newBrowser: NWBrowser) {
        lock.lock()
        let old = browser
        browser = newBrowser
        lock.unlock()
        old?.cancel()
    }

    func cancel() {
        lock.lock()
        let old = browser
        browser = nil
        lock.unlock()
        old?.cancel()
    }
}

private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func remoteEndpoint() -> NWEndpoint? {
        lock.lock()
        let endpoint = connection?.currentPath?.remoteEndpoint
        lock.unlock()
        return endpoint
    }

    func cancel() {
        lock.lock()
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.stateUpdateHandler = nil
        conn?.cancel()
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
#endif
