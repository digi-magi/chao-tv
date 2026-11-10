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
    private var extraObservers: [NSObjectProtocol] = []
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
            for name in [LibraryStore.changedNotification, WatchedStore.changedNotification] {
                extraObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.schedulePush() }
                })
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
        await syncTable(hub: hub, table: "library")
        await syncTable(hub: hub, table: "watched")
    }

    private func schedulePush() {
        guard !isApplyingRemote else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let hub = await ChaoLink.shared.resolveHub() else { return }
            await self?.push(hub: hub)
            await self?.syncTable(hub: hub, table: "library", pullFirst: false)
            await self?.syncTable(hub: hub, table: "watched", pullFirst: false)
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

    // MARK: - Library + watched (same hub rules, keyed "type:id[:s:e]")

    private static func kind(_ type: String) -> String { type == "movie" ? "movie" : "series" }

    /// Local rows for a table: key -> (stamp ms, wire record).
    private func localRows(_ table: String) -> [String: (Int64, [String: Any])] {
        var rows: [String: (Int64, [String: Any])] = [:]
        if table == "library" {
            for item in LibraryStore.items() {
                let type = Self.kind(item.meta.type)
                let stamp = Self.ms(item.addedAt)
                var rec: [String: Any] = ["id": item.meta.id, "type": type, "name": item.meta.name, "addedAt": stamp]
                if let poster = item.meta.posterUrl { rec["poster"] = poster }
                rows["\(type):\(item.meta.id)"] = (stamp, rec)
            }
        } else {
            for item in WatchedStore.items() {
                let type = Self.kind(item.meta.type)
                let stamp = Self.ms(item.watchedAt)
                var key = "\(type):\(item.meta.id)"
                var rec: [String: Any] = ["id": item.meta.id, "type": type, "name": item.meta.name, "watchedAt": stamp]
                if let season = item.season, let episode = item.episode {
                    key += ":\(season):\(episode)"; rec["season"] = season; rec["episode"] = episode
                }
                rows[key] = (stamp, rec)
            }
        }
        return rows
    }

    private func tableState(_ table: String) -> [String: Int64] {
        (defaults.dictionary(forKey: "chaotv.sync.\(table).pushed") ?? [:]).compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    private func setTableState(_ table: String, _ map: [String: Int64]) {
        defaults.set(map, forKey: "chaotv.sync.\(table).pushed")
    }

    private var metaCache: [String: NuvioMeta] = [:]

    private func meta(id: String, type: String) async -> NuvioMeta? {
        if let hit = metaCache["\(type):\(id)"] { return hit }
        let lookup = await ContinueWatchingBuilder.lookupMetadata(
            id: id, type: type, needsVideos: false, repository: CinemetaCatalogRepository())
        if let found = lookup.meta { metaCache["\(type):\(id)"] = found }
        return lookup.meta
    }

    func syncTable(hub: URL, table: String, pullFirst: Bool = true) async {
        var sent = tableState(table)
        if pullFirst {
            // Pull: apply other devices' adds/removes.
            let cursorKey = "chaotv.sync.\(table).cursor"
            let cursor = (defaults.object(forKey: cursorKey) as? NSNumber)?.int64Value ?? 0
            var comps = URLComponents(url: hub.appendingPathComponent(table), resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "since", value: String(cursor))]
            if let url = comps?.url,
               let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let local = localRows(table)
                isApplyingRemote = true
                for item in object["items"] as? [[String: Any]] ?? [] {
                    guard let key = item["key"] as? String else { continue }
                    let updatedAt = (item["updatedAt"] as? NSNumber)?.int64Value ?? 0
                    if let mine = local[key], mine.0 > updatedAt { continue }
                    let parts = key.split(separator: ":").map(String.init)
                    guard parts.count >= 2 else { continue }
                    let type = parts[0], id = parts[1]
                    let season = parts.count >= 4 ? Int(parts[2]) : nil
                    let episode = parts.count >= 4 ? Int(parts[3]) : nil
                    if item["deleted"] as? Bool == true {
                        if local[key] != nil {
                            if table == "library" {
                                LibraryStore.remove(metaId: id, type: type)
                            } else if let season, let episode {
                                if let m = await meta(id: id, type: type) {
                                    _ = WatchedStore.removeEpisode(meta: m, season: season, episode: episode)
                                }
                            } else {
                                _ = WatchedStore.remove(metaId: id, type: type)
                            }
                        }
                        sent.removeValue(forKey: key)
                        continue
                    }
                    if local[key] != nil { sent[key] = max(sent[key] ?? 0, updatedAt); continue }
                    guard let m = await meta(id: id, type: type) else { continue }
                    if table == "library" {
                        LibraryStore.add(m)
                    } else {
                        _ = WatchedStore.markWatched(m, season: season, episode: episode)
                    }
                    sent[key] = Int64.max / 2   // applied from the hub: never echo it back as new
                }
                isApplyingRemote = false
                defaults.set((object["now"] as? NSNumber)?.int64Value ?? cursor, forKey: cursorKey)
            }
        }
        // Push: local adds/changes and removals.
        let local = localRows(table)
        var items: [[String: Any]] = []
        for (key, row) in local where (sent[key] ?? -1) < row.0 {
            var item = row.1; item["key"] = key; item["updatedAt"] = row.0
            items.append(item); sent[key] = row.0
        }
        let now = Self.ms(Date())
        for key in sent.keys where local[key] == nil {
            items.append(["key": key, "updatedAt": now, "deleted": true])
            sent.removeValue(forKey: key)
        }
        if !items.isEmpty {
            var request = URLRequest(url: hub.appendingPathComponent(table))
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["device": ChaoLink.shared.deviceName, "items": items])
            guard let (_, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        }
        setTableState(table, sent)
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
