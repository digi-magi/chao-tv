import Foundation
import UIKit

/// Chao TV's agent link ("back door").
///
/// While the app is in the foreground it long-polls the house hub
/// (`/chaotv/link/poll` on the stremio-cache add-on) for commands, runs them
/// through the handler the root view installs, and reports the result plus a
/// snapshot of what is on screen. This lets the house agent drive the app
/// directly instead of pressing remote buttons and reading screenshots.
///
/// The hub address is never hard-coded: it is the origin of whichever
/// installed stream add-on answers `/chaotv/devices`.
@MainActor
final class ChaoLink {
    static let shared = ChaoLink()

    struct Command {
        let id: String
        let name: String
        let args: [String: Any]

        func string(_ key: String) -> String? {
            if let s = args[key] as? String, !s.isEmpty { return s }
            if let n = args[key] as? NSNumber { return n.stringValue }
            return nil
        }

        func int(_ key: String) -> Int? {
            if let n = args[key] as? NSNumber { return n.intValue }
            if let s = args[key] as? String { return Int(s) }
            return nil
        }

        func double(_ key: String) -> Double? {
            if let n = args[key] as? NSNumber { return n.doubleValue }
            if let s = args[key] as? String { return Double(s) }
            return nil
        }
    }

    struct Result {
        let ok: Bool
        let info: [String: Any]

        static func ok(_ info: [String: Any] = [:]) -> Result { Result(ok: true, info: info) }
        static func fail(_ message: String) -> Result { Result(ok: false, info: ["error": message]) }
    }

    /// Runs one command. Installed by the root view.
    var handler: (@MainActor (Command) async -> Result)?
    /// Snapshot of the current screen / player, sent with every report.
    var stateProvider: (@MainActor () -> [String: Any])?

    let deviceName: String = UIDevice.current.name
    private(set) var hubBase: URL?
    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 40
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private init() {}

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.runLoop() }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.reportState()
            }
        }
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
    }

    // MARK: - Hub discovery

    /// The hub lives on the same server as the house's stream add-on.
    func resolveHub() async -> URL? {
        if let hubBase { return hubBase }
        var origins: [URL] = []
        for manifest in CinemetaCatalogRepository.configuredStreamAddonManifestURLs {
            guard let scheme = manifest.scheme, scheme.hasPrefix("http"),
                  var comps = URLComponents(url: manifest, resolvingAgainstBaseURL: false) else { continue }
            comps.path = "/chaotv"
            comps.query = nil
            if let url = comps.url, !origins.contains(url) { origins.append(url) }
        }
        for base in origins {
            var request = URLRequest(url: base.appendingPathComponent("devices"))
            request.timeoutInterval = 4
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                hubBase = base
                return base
            }
        }
        return nil
    }

    // MARK: - Loop

    private func runLoop() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            guard let hub = await resolveHub() else {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                continue
            }
            var comps = URLComponents(url: hub.appendingPathComponent("link/poll"), resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "device", value: deviceName),
                                 URLQueryItem(name: "wait", value: "25")]
            guard let url = comps?.url else { return }
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                backoff = 2
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let commands = object?["commands"] as? [[String: Any]] ?? []
                for raw in commands {
                    guard let id = raw["id"] as? String, let name = raw["cmd"] as? String else { continue }
                    let command = Command(id: id, name: name, args: raw["args"] as? [String: Any] ?? [:])
                    await run(command)
                }
            } catch {
                if Task.isCancelled { return }
                hubBase = nil
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func run(_ command: Command) async {
        let result: Result
        if let handler {
            result = await handler(command)
        } else {
            result = .fail("app not ready")
        }
        await post("link/result", body: ["device": deviceName, "id": command.id, "ok": result.ok, "info": result.info])
        // Let the UI settle so the reported state reflects the command.
        try? await Task.sleep(nanoseconds: 400_000_000)
        await reportState()
    }

    func reportState() async {
        guard hubBase != nil else { return }
        let state = stateProvider?() ?? [:]
        await post("link/state", body: ["device": deviceName, "state": state])
    }

    private func post(_ path: String, body: [String: Any]) async {
        guard let hub = hubBase,
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: hub.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 8
        _ = try? await session.data(for: request)
    }
}
