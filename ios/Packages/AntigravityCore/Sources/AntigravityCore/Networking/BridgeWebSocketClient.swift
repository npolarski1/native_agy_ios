import Foundation

public enum ConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    public var displayLabel: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Live"
        case .reconnecting(let attempt):
            return "Reconnecting (\(attempt))"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }
}

public actor BridgeWebSocketClient {
    public let baseURL: URL
    private let token: String
    private let session: URLSession
    private let pingIntervalSeconds: TimeInterval
    private let maxReconnectDelaySeconds: TimeInterval

    private var state: ConnectionState = .disconnected
    private var isRunning: Bool = false
    private var reconnectAttempt: Int = 0
    private var webSocketTask: URLSessionWebSocketTask?
    private var supervisorTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private var eventContinuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    public init(
        baseURL: URL,
        token: String,
        session: URLSession = .shared,
        pingIntervalSeconds: TimeInterval = 20,
        maxReconnectDelaySeconds: TimeInterval = 30
    ) {
        self.baseURL = (try? PairingURI.normalizeBaseURL(baseURL.absoluteString)) ?? baseURL
        self.token = token
        self.session = session
        self.pingIntervalSeconds = max(5, pingIntervalSeconds)
        self.maxReconnectDelaySeconds = max(1, maxReconnectDelaySeconds)
    }

    deinit {
        pingTask?.cancel()
        supervisorTask?.cancel()
    }

    // MARK: - Streams & State

    public func currentState() -> ConnectionState {
        state
    }

    public nonisolated func eventStream() -> AsyncStream<BridgeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BridgeEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeEventContinuation(id: id)
            }
        }
        Task { [weak self] in
            await self?.addEventContinuation(id: id, continuation: continuation)
        }
        return stream
    }

    public nonisolated func stateStream() -> AsyncStream<ConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeStateContinuation(id: id)
            }
        }
        Task { [weak self] in
            await self?.addStateContinuation(id: id, continuation: continuation)
        }
        return stream
    }

    // MARK: - Lifecycle

    public func connect() {
        guard !isRunning else { return }
        isRunning = true
        reconnectAttempt = 0
        supervisorTask?.cancel()
        supervisorTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    public func disconnect() {
        isRunning = false
        pingTask?.cancel()
        pingTask = nil
        supervisorTask?.cancel()
        supervisorTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        reconnectAttempt = 0
        updateState(.disconnected)
    }

    public func sendPing() async {
        guard let task = webSocketTask else { return }
        do {
            try await task.send(.string("{\"type\":\"ping\"}"))
        } catch {
            // Receive loop handles connection tear-down and reconnect.
        }
    }

    // MARK: - Static Helpers

    public static func webSocketURL(from baseURL: URL, token: String? = nil) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw BridgeAPIError.invalidURL(baseURL.absoluteString)
        }

        switch components.scheme?.lowercased() {
        case "http", "ws":
            components.scheme = "ws"
        case "https", "wss":
            components.scheme = "wss"
        default:
            throw BridgeAPIError.invalidURL(baseURL.absoluteString)
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path + "/api/v1/ws"

        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        } else {
            components.queryItems = nil
        }

        guard let url = components.url else {
            throw BridgeAPIError.invalidURL(baseURL.absoluteString)
        }
        return url
    }

    public static func reconnectDelay(forAttempt attempt: Int, maxDelay: TimeInterval = 30) -> TimeInterval {
        let clampedAttempt = max(1, attempt)
        let exponent = min(clampedAttempt - 1, 6)
        let rawDelay = Double(1 << exponent)
        return min(max(1.0, maxDelay), rawDelay)
    }

    // MARK: - Internal Connection Loop

    private func runConnectionLoop() async {
        while isRunning && !Task.isCancelled {
            let wsURL: URL
            do {
                wsURL = try Self.webSocketURL(from: baseURL, token: token)
            } catch {
                updateState(.failed(error.localizedDescription))
                isRunning = false
                return
            }

            if reconnectAttempt == 0 {
                updateState(.connecting)
            } else {
                updateState(.reconnecting(attempt: reconnectAttempt))
            }

            var request = URLRequest(url: wsURL)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let task = session.webSocketTask(with: request)
            self.webSocketTask = task
            task.resume()

            do {
                try await task.send(.string("{\"type\":\"ping\"}"))
                guard isRunning && !Task.isCancelled else {
                    task.cancel(with: .goingAway, reason: nil)
                    break
                }

                reconnectAttempt = 0
                updateState(.connected)
                startPingLoop()

                while isRunning && !Task.isCancelled {
                    let message = try await task.receive()
                    handleIncomingMessage(message)
                }
            } catch {
                pingTask?.cancel()
                pingTask = nil
                task.cancel(with: .abnormalClosure, reason: nil)
                if webSocketTask === task {
                    webSocketTask = nil
                }

                if !isRunning || Task.isCancelled {
                    break
                }

                reconnectAttempt += 1
                updateState(.reconnecting(attempt: reconnectAttempt))
                let delay = Self.reconnectDelay(forAttempt: reconnectAttempt, maxDelay: maxReconnectDelaySeconds)
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        if !isRunning {
            updateState(.disconnected)
        }
    }

    private func startPingLoop() {
        pingTask?.cancel()
        let interval = pingIntervalSeconds
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
                guard let self else { break }
                await self.sendPing()
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) {
        let payloadData: Data?
        switch message {
        case .string(let text):
            payloadData = text.data(using: .utf8)
        case .data(let data):
            payloadData = data
        @unknown default:
            payloadData = nil
        }

        guard let data = payloadData,
              let event = try? BridgeJSONDecoder.decode(BridgeEvent.self, from: data) else {
            return
        }

        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Continuation Registry

    private func addEventContinuation(id: UUID, continuation: AsyncStream<BridgeEvent>.Continuation) {
        eventContinuations[id] = continuation
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func addStateContinuation(id: UUID, continuation: AsyncStream<ConnectionState>.Continuation) {
        stateContinuations[id] = continuation
        continuation.yield(state)
    }

    private func removeStateContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func updateState(_ newState: ConnectionState) {
        guard state != newState else { return }
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }
}
