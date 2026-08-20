import Foundation
import SwiftUI

/// Talks to the Vitals agent, and only while the app is actually on screen.
///
/// The agent samples nothing until something subscribes to its event stream, so
/// holding this connection open is what costs the server. `scenePhase` drives
/// it: foreground opens the stream, background closes it. Nobody wants an app
/// in their pocket keeping a home server awake.
@MainActor
final class Client: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case live
        case paused
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "idle"
            case .connecting: return "connecting"
            case .live: return "live"
            case .paused: return "paused"
            case .failed: return "offline"
            }
        }
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var state: State = .idle
    @Published private(set) var history = History()

    @AppStorage("serverURL") var serverURL: String = "http://192.168.68.95:8321"
    @AppStorage("serverToken") var token: String = ""

    private var task: Task<Void, Never>?

    /// A short rolling window for the sparklines. Deliberately in memory only:
    /// the agent stores nothing, so neither does the app.
    struct History: Equatable {
        private(set) var cpu: [Double] = []
        private(set) var memory: [Double] = []
        private(set) var network: [Double] = []
        static let limit = 60

        mutating func append(_ snapshot: Snapshot) {
            push(&cpu, snapshot.cpu.percent)
            push(&memory, snapshot.memory.percent)
            let throughput = snapshot.network.first.map { $0.rx_rate + $0.tx_rate } ?? 0
            push(&network, throughput / 1024)
        }

        mutating func clear() { cpu = []; memory = []; network = [] }

        private func push(_ series: inout [Double], _ value: Double) {
            series.append(value)
            if series.count > Self.limit { series.removeFirst() }
        }
    }

    // MARK: Lifecycle

    func connect() {
        guard task == nil else { return }
        state = .connecting
        task = Task { [weak self] in await self?.stream() }
    }

    func disconnect(paused: Bool = true) {
        task?.cancel()
        task = nil
        if paused, snapshot != nil { state = .paused } else { state = .idle }
    }

    func reconnect() {
        disconnect(paused: false)
        history.clear()
        snapshot = nil
        connect()
    }

    // MARK: Networking

    private func request(path: String) -> URLRequest? {
        var text = serverURL.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "http://" + text }
        if text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text + path) else { return nil }
        if !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    /// Reads the server-sent event stream line by line. Reconnects with a small
    /// backoff, because a home server rebooting mid-view is normal.
    private func stream() async {
        var attempt = 0
        while !Task.isCancelled {
            guard let request = request(path: "/events") else {
                state = .failed("Bad server address")
                return
            }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    state = .failed(http.statusCode == 401
                                    ? "Token rejected" : "Server said \(http.statusCode)")
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                attempt = 0
                var event = ""
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    if line.hasPrefix("event:") {
                        event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:"), event == "sample" {
                        let payload = Data(line.dropFirst(5)
                            .trimmingCharacters(in: .whitespaces).utf8)
                        if let decoded = try? JSONDecoder().decode(Snapshot.self, from: payload) {
                            snapshot = decoded
                            history.append(decoded)
                            state = .live
                        }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                state = .failed(friendly(error))
            }
            if Task.isCancelled { return }
            attempt = min(attempt + 1, 5)
            try? await Task.sleep(for: .seconds(Double(attempt) * 2))
        }
    }

    private func friendly(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "Cannot reach the agent"
        case NSURLErrorNotConnectedToInternet: return "No network"
        case NSURLErrorTimedOut: return "Timed out"
        default: return "Connection lost"
        }
    }

    /// One-shot fetch, used by pull-to-refresh while paused.
    func refreshOnce() async {
        guard let request = request(path: "/api/snapshot") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
                snapshot = decoded
                history.append(decoded)
            }
        } catch {
            state = .failed(friendly(error))
        }
    }
}
