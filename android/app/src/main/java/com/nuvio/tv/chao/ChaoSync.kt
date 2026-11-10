package com.nuvio.tv.chao

import android.content.Context
import android.util.Log
import com.nuvio.tv.core.profile.ProfileManager
import com.nuvio.tv.data.local.WatchProgressPreferences
import com.nuvio.tv.domain.model.WatchProgress
import com.nuvio.tv.domain.repository.AddonRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Chao Sync: watch progress shared by every Chao TV in the house (Apple TV and
 * Google TV) through the hub at `/chaotv/progress` on the cache add-on's server.
 *
 * Wire format = the tvOS app's WatchProgressRecord: progressKey, contentId,
 * contentType, videoId, season, episode, position and duration in SECONDS,
 * lastWatchedAt in epoch ms. This app stores ms, so it converts both ways.
 * Newest lastWatchedAt wins; removals travel as tombstones.
 */
@Singleton
class ChaoSync @Inject constructor(
    @ApplicationContext private val context: Context,
    private val progressPrefs: WatchProgressPreferences,
    private val profileManager: ProfileManager,
    private val addonRepository: AddonRepository,
    private val libraryRepository: com.nuvio.tv.domain.repository.LibraryRepository,
    private val watchedPrefs: com.nuvio.tv.data.local.WatchedItemsPreferences,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val prefs = context.getSharedPreferences("chaotv_sync", Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private var loopJob: Job? = null
    private var watchJob: Job? = null
    @Volatile private var applyingRemote = false
    @Volatile var hubBase: String? = null
        private set
    private val metaCache = HashMap<String, JSONObject?>()

    /** Start (idempotent): pull/push now, every 60 s, and push on local changes. */
    @OptIn(FlowPreview::class)
    fun start() {
        if (loopJob?.isActive != true) {
            loopJob = scope.launch {
                while (true) {
                    runCatching { syncNow() }.onFailure { Log.w(TAG, "sync failed: ${it.message}") }
                    delay(60_000)
                }
            }
        }
        if (watchJob?.isActive != true) {
            watchJob = scope.launch {
                val profileId = profileManager.activeProfileId.value
                launch {
                    progressPrefs.observeAllRawProgress(profileId).debounce(2_000).collect {
                        if (!applyingRemote) runCatching { push() }
                    }
                }
                launch {
                    libraryRepository.libraryItems.debounce(2_000).collect {
                        if (!applyingRemote) runCatching { mutex.withLock { resolveHub()?.let { syncTable(it, "library", pullFirst = false) } } }
                    }
                }
                launch {
                    watchedPrefs.observeAllItems(profileId).debounce(2_000).collect {
                        if (!applyingRemote) runCatching { mutex.withLock { resolveHub()?.let { syncTable(it, "watched", pullFirst = false) } } }
                    }
                }
            }
        }
    }

    fun stop() {
        loopJob?.cancel(); loopJob = null
    }

    suspend fun syncNow() = mutex.withLock {
        val hub = resolveHub() ?: return@withLock
        pull(hub)
        pushLocked(hub)
        syncTable(hub, "library")
        syncTable(hub, "watched")
    }

    // ---- library + watched: same hub rules, keyed "type:id[:season:episode]"
    private fun kind(type: String) = if (type == "movie") "movie" else "series"

    private suspend fun localRows(table: String): Map<String, Pair<Long, JSONObject>> {
        val rows = LinkedHashMap<String, Pair<Long, JSONObject>>()
        if (table == "library") {
            for (e in libraryRepository.libraryItems.first()) {
                val type = kind(e.type); val stamp = if (e.listedAt > 0) e.listedAt else 1L
                rows["$type:${e.id}"] = stamp to JSONObject().put("id", e.id).put("type", type)
                    .put("name", e.name).put("poster", e.poster ?: JSONObject.NULL).put("addedAt", stamp)
            }
        } else {
            for (w in watchedPrefs.observeAllItems(profileManager.activeProfileId.value).first()) {
                val type = kind(w.contentType)
                val key = if (w.season != null && w.episode != null) "$type:${w.contentId}:${w.season}:${w.episode}" else "$type:${w.contentId}"
                val rec = JSONObject().put("id", w.contentId).put("type", type).put("name", w.title).put("watchedAt", w.watchedAt)
                if (w.season != null && w.episode != null) rec.put("season", w.season).put("episode", w.episode)
                rows[key] = w.watchedAt to rec
            }
        }
        return rows
    }

    private fun loadTable(table: String): MutableMap<String, Long> {
        val o = runCatching { JSONObject(prefs.getString("$table.pushed", null) ?: "{}") }.getOrNull() ?: JSONObject()
        return o.keys().asSequence().associateWith { o.optLong(it) }.toMutableMap()
    }

    private fun saveTable(table: String, map: Map<String, Long>) {
        val o = JSONObject(); map.forEach { (k, v) -> o.put(k, v) }
        prefs.edit().putString("$table.pushed", o.toString()).apply()
    }

    private suspend fun syncTable(hub: String, table: String, pullFirst: Boolean = true) {
        val sent = loadTable(table)
        if (pullFirst) {
            val cursor = prefs.getLong("$table.cursor", 0L)
            val (code, text) = http("GET", "$hub/$table?since=$cursor", null, 10_000)
            if (code == 200 && text != null) {
                val obj = JSONObject(text)
                val items = obj.optJSONArray("items") ?: JSONArray()
                val local = localRows(table)
                val profileId = profileManager.activeProfileId.value
                applyingRemote = true
                try {
                    for (i in 0 until items.length()) {
                        val item = items.optJSONObject(i) ?: continue
                        val key = item.optString("key")
                        if (key.isBlank()) continue
                        val updatedAt = item.optLong("updatedAt")
                        val mine = local[key]
                        if (mine != null && mine.first > updatedAt) continue
                        val parts = key.split(":")
                        if (parts.size < 2) continue
                        val type = parts[0]; val id = parts[1]
                        val season = parts.getOrNull(2)?.toIntOrNull(); val episode = parts.getOrNull(3)?.toIntOrNull()
                        if (item.optBoolean("deleted")) {
                            if (mine != null) {
                                if (table == "library") {
                                    libraryRepository.toggleDefault(com.nuvio.tv.domain.model.LibraryEntryInput(itemId = id, itemType = type, title = mine.second.optString("name", id)))
                                } else {
                                    watchedPrefs.unmarkAsWatched(id, season, episode, profileId)
                                }
                            }
                            sent.remove(key); continue
                        }
                        if (mine != null) { sent[key] = maxOf(sent[key] ?: 0L, updatedAt); continue }
                        val meta = cinemeta(type, id)
                        val name = item.optString("name").takeIf { it.isNotBlank() && it != "null" } ?: meta?.optString("name") ?: id
                        val poster = item.optString("poster").takeIf { it.isNotBlank() && it != "null" } ?: meta?.optString("poster")
                        if (table == "library") {
                            libraryRepository.toggleDefault(com.nuvio.tv.domain.model.LibraryEntryInput(
                                itemId = id, itemType = type, title = name, poster = poster,
                                background = meta?.optString("background")?.takeIf { it.isNotBlank() },
                                logo = meta?.optString("logo")?.takeIf { it.isNotBlank() },
                                description = meta?.optString("description")?.takeIf { it.isNotBlank() },
                                releaseInfo = meta?.optString("releaseInfo")?.takeIf { it.isNotBlank() }))
                        } else {
                            watchedPrefs.markAsWatched(com.nuvio.tv.domain.model.WatchedItem(
                                contentId = id, contentType = type, title = name, season = season, episode = episode,
                                watchedAt = item.optLong("watchedAt", updatedAt), poster = poster), profileId)
                        }
                        sent[key] = Long.MAX_VALUE / 2   // applied from the hub: never echo it back as new
                    }
                } finally {
                    applyingRemote = false
                }
                prefs.edit().putLong("$table.cursor", obj.optLong("now", cursor)).apply()
            }
        }
        val local = localRows(table)
        val out = JSONArray()
        for ((key, row) in local) {
            if ((sent[key] ?: -1L) >= row.first) continue
            out.put(JSONObject(row.second.toString()).put("key", key).put("updatedAt", row.first))
            sent[key] = row.first
        }
        val now = System.currentTimeMillis()
        for (key in sent.keys.toList()) {
            if (!local.containsKey(key)) { out.put(JSONObject().put("key", key).put("updatedAt", now).put("deleted", true)); sent.remove(key) }
        }
        if (out.length() > 0) {
            val (code, _) = http("PUT", "$hub/$table", JSONObject().put("device", ChaoLink.deviceName()).put("items", out).toString(), 15_000)
            if (code != 200) return
        }
        saveTable(table, sent)
    }

    // ---- hub discovery: the origin of whichever installed add-on answers /chaotv/devices
    suspend fun resolveHub(): String? {
        hubBase?.let { return it }
        val origins = runCatching { addonRepository.getInstalledAddons().first() }.getOrDefault(emptyList())
            .mapNotNull { addon ->
                runCatching { URL(addon.baseUrl) }.getOrNull()
                    ?.takeIf { it.protocol.startsWith("http") }
                    ?.let { "${it.protocol}://${it.authority}/chaotv" }
            }.distinct()
        for (base in origins) {
            val ok = runCatching { http("GET", "$base/devices", null, 4_000).first == 200 }.getOrDefault(false)
            if (ok) { hubBase = base; return base }
        }
        return null
    }

    // ---- push
    private suspend fun push() = mutex.withLock { resolveHub()?.let { pushLocked(it) } }

    private suspend fun pushLocked(hub: String) {
        val profileId = profileManager.activeProfileId.value
        val local = progressPrefs.getAllRawEntries(profileId)
        val sent = loadPushed()
        val items = JSONArray()
        for ((key, p) in local) {
            if (p.source != WatchProgress.SOURCE_LOCAL && p.source != WatchProgress.SOURCE_REMOTE_PLAYBACK) continue
            val last = sent[key]
            if (last != null && last >= p.lastWatched) continue
            items.put(JSONObject().put("key", key).put("updatedAt", p.lastWatched).put("record", toRecord(key, p)))
            sent[key] = p.lastWatched
        }
        val now = System.currentTimeMillis()
        for (key in sent.keys.toList()) {
            if (!local.containsKey(key)) {
                items.put(JSONObject().put("key", key).put("updatedAt", now).put("deleted", true))
                sent.remove(key)
            }
        }
        if (items.length() == 0) return
        val body = JSONObject().put("device", ChaoLink.deviceName()).put("items", items).toString()
        val (code, _) = http("PUT", "$hub/progress", body, 10_000)
        if (code == 200) savePushed(sent)
    }

    // ---- pull
    private suspend fun pull(hub: String) {
        val cursor = prefs.getLong(KEY_CURSOR, 0L)
        val (code, text) = http("GET", "$hub/progress?since=$cursor", null, 10_000)
        if (code != 200 || text == null) return
        val obj = JSONObject(text)
        val items = obj.optJSONArray("items") ?: JSONArray()
        val profileId = profileManager.activeProfileId.value
        val local = progressPrefs.getAllRawEntries(profileId)
        val sent = loadPushed()
        val upserts = LinkedHashMap<String, WatchProgress>()
        val deletes = ArrayList<String>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val key = item.optString("key")
            if (key.isBlank()) continue
            val updatedAt = item.optLong("updatedAt")
            val mine = local[key]
            if (item.optBoolean("deleted")) {
                if (mine != null && mine.lastWatched > updatedAt) continue
                if (mine != null) deletes.add(key)
                sent.remove(key)
                continue
            }
            val rec = item.optJSONObject("record") ?: continue
            val incoming = fromRecord(rec, mine) ?: continue
            if (mine != null && mine.lastWatched >= incoming.lastWatched) continue
            upserts[key] = incoming
            sent[key] = incoming.lastWatched
        }
        if (upserts.isNotEmpty() || deletes.isNotEmpty()) {
            applyingRemote = true
            try {
                progressPrefs.applyRemoteChanges(upserts = upserts, deletes = deletes, profileId = profileId)
                savePushed(sent)
            } finally {
                applyingRemote = false
            }
            Log.i(TAG, "pulled ${upserts.size} upserts, ${deletes.size} deletes")
        }
        prefs.edit().putLong(KEY_CURSOR, obj.optLong("now", cursor)).apply()
    }

    // ---- conversion (wire = seconds, local = ms)
    private fun toRecord(key: String, p: WatchProgress): JSONObject = JSONObject()
        .put("progressKey", key)
        .put("contentId", p.contentId)
        .put("contentType", if (p.contentType == "movie") "movie" else "series")
        .put("videoId", p.videoId)
        .put("season", p.season ?: JSONObject.NULL)
        .put("episode", p.episode ?: JSONObject.NULL)
        .put("position", p.position / 1000.0)
        .put("duration", p.duration / 1000.0)
        .put("lastWatchedAt", p.lastWatched)
        .put("isPendingPush", false)
        // Extra fields for other Android installs; the tvOS decoder ignores them.
        .put("name", p.name)
        .put("poster", p.poster ?: JSONObject.NULL)
        .put("backdrop", p.backdrop ?: JSONObject.NULL)
        .put("logo", p.logo ?: JSONObject.NULL)
        .put("episodeTitle", p.episodeTitle ?: JSONObject.NULL)

    private fun fromRecord(r: JSONObject, mine: WatchProgress?): WatchProgress? {
        val contentId = r.optString("contentId").ifBlank { return null }
        val type = r.optString("contentType", "movie").let { if (it == "movie") "movie" else "series" }
        val season = if (r.isNull("season")) null else r.optInt("season")
        val episode = if (r.isNull("episode")) null else r.optInt("episode")
        val videoId = r.optString("videoId").ifBlank {
            if (season != null && episode != null) "$contentId:$season:$episode" else contentId
        }
        var name = r.optString("name").takeIf { it.isNotBlank() && it != "null" } ?: mine?.name
        var poster = r.optString("poster").takeIf { it.isNotBlank() && it != "null" } ?: mine?.poster
        var backdrop = r.optString("backdrop").takeIf { it.isNotBlank() && it != "null" } ?: mine?.backdrop
        var logo = r.optString("logo").takeIf { it.isNotBlank() && it != "null" } ?: mine?.logo
        if (name == null || poster == null) {
            cinemeta(type, contentId)?.let { m ->
                name = name ?: m.optString("name").takeIf { it.isNotBlank() }
                poster = poster ?: m.optString("poster").takeIf { it.isNotBlank() }
                backdrop = backdrop ?: m.optString("background").takeIf { it.isNotBlank() }
                logo = logo ?: m.optString("logo").takeIf { it.isNotBlank() }
            }
        }
        return WatchProgress(
            contentId = contentId,
            contentType = type,
            name = name ?: contentId,
            poster = poster,
            backdrop = backdrop,
            logo = logo,
            videoId = videoId,
            season = season,
            episode = episode,
            episodeTitle = r.optString("episodeTitle").takeIf { it.isNotBlank() && it != "null" } ?: mine?.episodeTitle,
            position = (r.optDouble("position", 0.0) * 1000).toLong(),
            duration = (r.optDouble("duration", 0.0) * 1000).toLong(),
            lastWatched = r.optLong("lastWatchedAt"),
            source = WatchProgress.SOURCE_LOCAL,
        )
    }

    fun cinemeta(type: String, id: String): JSONObject? = synchronized(metaCache) {
        metaCache.getOrPut("$type/$id") {
            runCatching {
                val (code, text) = http("GET", "https://v3-cinemeta.strem.io/meta/$type/$id.json", null, 8_000)
                if (code == 200 && text != null) JSONObject(text).optJSONObject("meta") else null
            }.getOrNull()
        }
    }

    // ---- bookkeeping: key -> lastWatched we last sent or received
    private fun loadPushed(): MutableMap<String, Long> {
        val raw = prefs.getString(KEY_PUSHED, null) ?: return mutableMapOf()
        val o = runCatching { JSONObject(raw) }.getOrNull() ?: return mutableMapOf()
        return o.keys().asSequence().associateWith { o.optLong(it) }.toMutableMap()
    }

    private fun savePushed(map: Map<String, Long>) {
        val o = JSONObject(); map.forEach { (k, v) -> o.put(k, v) }
        prefs.edit().putString(KEY_PUSHED, o.toString()).apply()
    }

    companion object {
        private const val TAG = "ChaoSync"
        private const val KEY_PUSHED = "pushed"
        private const val KEY_CURSOR = "cursor"

        /** Tiny HTTP helper (no extra dependencies). Returns (status, body). */
        fun http(method: String, url: String, body: String?, timeoutMs: Int): Pair<Int, String?> {
            val conn = URL(url).openConnection() as HttpURLConnection
            return try {
                conn.requestMethod = method
                conn.connectTimeout = timeoutMs
                conn.readTimeout = timeoutMs
                if (body != null) {
                    conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/json")
                    conn.outputStream.use { it.write(body.toByteArray()) }
                }
                val code = conn.responseCode
                val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                    ?.bufferedReader()?.use { it.readText() }
                code to text
            } finally {
                conn.disconnect()
            }
        }
    }
}
