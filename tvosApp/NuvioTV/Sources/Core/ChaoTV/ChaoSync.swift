import Foundation

/// Chao Sync: watch progress shared by every Chao TV in the house.
///
/// The raw progress ledger (`WatchProgressLedger`) is mirrored to the house hub
/// (`/chaotv/progress` on the stremio-cache add-on). Each device pushes rows it
/// changed and pulls rows other devices changed; the newest `lastWatchedAt`
/// wins and removals travel as tombstones. Continue Watching is rebuilt from
/// the ledger after every pull that changed something.
@MainActor
final class ChaoSync {
    static let shared = ChaoSync()

    private let defaults = UserDefaults.standard
    private let pushedKey = "chaotv.sync.pushed"      // progressKey -> lastWatchedAt ms we last sent/saw
    private let cursorKey = "chaotv.sync.cursor"      // hub `now` of the last pull
    private var loopTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var isApplyingRemote = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private init() {}

    func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: WatchProgressLedger.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.schedulePush() }
            }
        }
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
    }

    /// Pull then push. Safe to call any time (foreground, Home appearing).
    func syncNow() async {
        guard let hub = await ChaoLink.shared.resolveHub() else { return }
        await pull(hub: hub)
        await push(hub: hub)
    }

    private func schedulePush() {
        guard !isApplyingRemote else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let hub = await ChaoLink.shared.resolveHub() else { return }
            await self?.push(hub: hub)
        }
    }

    // MARK: - Bookkeeping

    private var pushed: [String: Int64] {
        get { (defaults.dictionary(forKey: pushedKey) ?? [:]).compactMapValues { ($0 as? NSNumber)?.int64Value } }
        set { defaults.set(newValue, forKey: pushedKey) }
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d
    }()

    // MARK: - Push

    private func push(hub: URL) async {
        let records = WatchProgressLedger.records()
        var sent = pushed
        var items: [[String: Any]] = []
        var present = Set<String>()
        for record in records {
            present.insert(record.progressKey)
            let stamp = Self.ms(record.lastWatchedAt)
            if let last = sent[record.progressKey], last >= stamp { continue }
            guard let data = try? Self.encoder.encode(record),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            items.append(["key": record.progressKey, "updatedAt": stamp, "record": json])
            sent[record.progressKey] = stamp
        }
        let now = Self.ms(Date())
        for key in sent.keys where !present.contains(key) {
            items.append(["key": key, "updatedAt": now, "deleted": true])
            sent.removeValue(forKey: key)
        }
        guard !items.isEmpty else { return }
        var request = URLRequest(url: hub.appendingPathComponent("progress"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device": ChaoLink.shared.deviceName, "items": items
        ])
        guard let (_, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        pushed = sent
    }

    // MARK: - Pull

    private func pull(hub: URL) async {
        let cursor = (defaults.object(forKey: cursorKey) as? NSNumber)?.int64Value ?? 0
        var comps = URLComponents(url: hub.appendingPathComponent("progress"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "since", value: String(cursor))]
        guard let url = comps?.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let items = object["items"] as? [[String: Any]] ?? []
        let hubNow = (object["now"] as? NSNumber)?.int64Value ?? cursor

        var incoming: [WatchProgressRecord] = []
        var removals: [String] = []
        var seen = pushed
        let local = Dictionary(WatchProgressLedger.records().map { ($0.progressKey, $0) },
                               uniquingKeysWith: { a, _ in a })
        for item in items {
            guard let key = item["key"] as? String else { continue }
            let updatedAt = (item["updatedAt"] as? NSNumber)?.int64Value ?? 0
            if item["deleted"] as? Bool == true {
                if let mine = local[key], Self.ms(mine.lastWatchedAt) > updatedAt { continue }
                if local[key] != nil { removals.append(key) }
                seen.removeValue(forKey: key)
                continue
            }
            guard let json = item["record"],
                  JSONSerialization.isValidJSONObject(json),
                  let recordData = try? JSONSerialization.data(withJSONObject: json),
                  var record = try? Self.decoder.decode(WatchProgressRecord.self, from: recordData) else { continue }
            if let mine = local[key], mine.lastWatchedAt >= record.lastWatchedAt { continue }
            record.isPendingPush = false
            incoming.append(record)
            seen[key] = Self.ms(record.lastWatchedAt)
        }

        if !incoming.isEmpty || !removals.isEmpty {
            isApplyingRemote = true
            if !incoming.isEmpty { _ = WatchProgressLedger.mergeRemote(incoming) }
            if !removals.isEmpty { _ = WatchProgressLedger.remove(keys: removals) }
            pushed = seen
            isApplyingRemote = false
            ContinueWatchingBuilder.scheduleRebuild(reason: "chao sync")
        }
        defaults.set(hubNow, forKey: cursorKey)
    }
}
