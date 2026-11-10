package com.nuvio.tv.chao

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import com.nuvio.tv.MainActivity
import com.nuvio.tv.core.deeplink.DeepLinkHandler
import com.nuvio.tv.ui.screens.player.PlayerEvent
import com.nuvio.tv.ui.screens.player.PlayerViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Chao TV agent link ("back door"), Android side. Same protocol as the tvOS app:
 * long-poll `/chaotv/link/poll`, run each command, report result + state.
 */
@Singleton
class ChaoLink @Inject constructor(
    @ApplicationContext private val context: Context,
    private val chaoSync: ChaoSync,
    private val deepLinkHandler: DeepLinkHandler,
    private val libraryRepository: com.nuvio.tv.domain.repository.LibraryRepository,
    private val progressRepository: com.nuvio.tv.domain.repository.WatchProgressRepository,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var loopJob: Job? = null
    private var heartbeatJob: Job? = null
    private val main = Handler(Looper.getMainLooper())

    init { appContext = context.applicationContext }

    fun start() {
        if (loopJob?.isActive == true) return
        loopJob = scope.launch { runLoop() }
        heartbeatJob = scope.launch {
            while (true) { delay(15_000); reportState() }
        }
    }

    fun stop() {
        loopJob?.cancel(); loopJob = null
        heartbeatJob?.cancel(); heartbeatJob = null
    }

    private suspend fun runLoop() {
        var backoff = 2_000L
        while (true) {
            val hub = chaoSync.resolveHub()
            if (hub == null) { delay(30_000); continue }
            val name = Uri.encode(deviceName())
            val result = runCatching { ChaoSync.http("GET", "$hub/link/poll?device=$name&wait=25", null, 35_000) }
            val (code, text) = result.getOrElse { 0 to null }
            if (code != 200 || text == null) {
                delay(backoff); backoff = (backoff * 2).coerceAtMost(30_000); continue
            }
            backoff = 2_000L
            val commands = JSONObject(text).optJSONArray("commands") ?: JSONArray()
            for (i in 0 until commands.length()) {
                val c = commands.optJSONObject(i) ?: continue
                val id = c.optString("id"); val cmd = c.optString("cmd")
                val args = c.optJSONObject("args") ?: JSONObject()
                val res = runCatching { handle(cmd, args) }.getOrElse { JSONObject().put("ok", false).put("error", it.message) }
                post("link/result", JSONObject().put("device", deviceName()).put("id", id)
                    .put("ok", res.optBoolean("ok")).put("info", res))
                delay(400)
                reportState()
            }
        }
    }

    private suspend fun reportState() {
        if (chaoSync.hubBase == null) return
        post("link/state", JSONObject().put("device", deviceName()).put("state", state()))
    }

    private suspend fun post(path: String, body: JSONObject) {
        val hub = chaoSync.hubBase ?: return
        runCatching { ChaoSync.http("POST", "$hub/$path", body.toString(), 8_000) }
    }

    private fun state(): JSONObject {
        val s = JSONObject().put("route", currentRoute ?: "unknown")
        currentDetails?.let { s.put("id", it.first).put("type", it.second) }
        player?.get()?.let { vm ->
            val ui = vm.uiState.value; val t = vm.playbackTimeline.value
            s.put("screen", "player").put("player", JSONObject()
                .put("title", ui.title).put("playing", ui.isPlaying)
                .put("position", t.currentPosition / 1000.0).put("duration", t.duration / 1000.0))
        } ?: s.put("screen", if (currentDetails != null) "details" else "main")
        return s
    }

    private fun ok(info: JSONObject = JSONObject()) = info.put("ok", true)
    private fun fail(msg: String) = JSONObject().put("ok", false).put("error", msg)

    private suspend fun handle(cmd: String, a: JSONObject): JSONObject {
        val vm = player?.get()
        return when (cmd) {
            "status" -> ok(state())
            "toast" -> { toast(a.optString("text", "Done")); ok() }
            "home", "tab", "back" -> {
                val nav = navigate ?: return fail("app not on screen")
                val route = when (if (cmd == "tab") a.optString("name", "home").lowercase() else cmd) {
                    "home" -> "home"; "search" -> "search"; "library" -> "library"; "settings" -> "settings"
                    "back" -> "back"
                    else -> return fail("unknown tab")
                }
                nav(route); ok()
            }
            "open" -> {
                val id = a.optString("id").ifBlank { return fail("id required") }
                openUri("nuvio://meta?type=${Uri.encode(a.optString("type", "movie"))}&id=${Uri.encode(id)}"); ok()
            }
            "play" -> {
                val id = a.optString("id").ifBlank { return fail("id required") }
                val season = if (a.has("season")) a.optInt("season") else null
                val episode = if (a.has("episode")) a.optInt("episode") else null
                val type = a.optString("type", if (season != null) "series" else "movie")
                val intent = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    putExtra("contentId", id); putExtra("contentType", type)
                    putExtra("videoId", if (season != null && episode != null) "$id:$season:$episode" else id)
                    putExtra("launchMode", "stream")
                    if (season != null) putExtra("season", season)
                    if (episode != null) putExtra("episode", episode)
                }
                withContext(Dispatchers.Main) { context.startActivity(intent) }
                toast(if (season != null) "Playing S${season}E${episode}" else "Playing")
                ok()
            }
            "pause", "resume" -> {
                vm ?: return fail("nothing playing")
                val playing = vm.uiState.value.isPlaying
                if ((cmd == "pause") == playing) withContext(Dispatchers.Main) { vm.onEvent(PlayerEvent.OnPlayPause) }
                ok()
            }
            "seek" -> {
                vm ?: return fail("nothing playing")
                val ev = when {
                    a.has("seconds") -> PlayerEvent.OnSeekTo((a.optDouble("seconds") * 1000).toLong())
                    a.has("by") -> PlayerEvent.OnSeekBy((a.optDouble("by") * 1000).toLong())
                    else -> return fail("seconds or by required")
                }
                withContext(Dispatchers.Main) { vm.onEvent(ev) }; ok()
            }
            "tracks" -> {
                vm ?: return fail("nothing playing")
                val ui = vm.uiState.value
                fun list(ts: List<com.nuvio.tv.ui.screens.player.TrackInfo>) = JSONArray().apply {
                    ts.forEach { put(JSONObject().put("id", it.index).put("name", it.name).put("language", it.language).put("selected", it.isSelected)) }
                }
                ok(JSONObject().put("audio", list(ui.audioTracks)).put("subtitles", list(ui.subtitleTracks)))
            }
            "audio", "subtitle" -> {
                vm ?: return fail("nothing playing")
                val ui = vm.uiState.value
                val wanted = a.optString("id").ifBlank { a.optString("language") }
                if (cmd == "subtitle" && wanted == "off") {
                    withContext(Dispatchers.Main) { vm.onEvent(PlayerEvent.OnDisableSubtitles) }
                    toast("Subtitles off"); return ok()
                }
                val pool = if (cmd == "audio") ui.audioTracks else ui.subtitleTracks
                val t = pool.firstOrNull { it.index.toString() == wanted }
                    ?: pool.firstOrNull { (it.language ?: "").equals(wanted, ignoreCase = true) }
                    ?: return fail("no $cmd track $wanted")
                withContext(Dispatchers.Main) {
                    vm.onEvent(if (cmd == "audio") PlayerEvent.OnSelectAudioTrack(t.index) else PlayerEvent.OnSelectSubtitleTrack(t.index))
                }
                toast((if (cmd == "audio") "Audio: " else "Subtitles: ") + t.name); ok()
            }
            "next" -> {
                vm ?: return fail("nothing playing")
                withContext(Dispatchers.Main) { vm.onEvent(PlayerEvent.OnPlayNextEpisode) }; ok()
            }
            "addon" -> {
                val url = a.optString("url").ifBlank { return fail("url required") }
                val r = deepLinkHandler.installAddon(url)
                toast("Add-on installed"); ok(JSONObject().put("message", r.message))
            }
            "sync" -> { chaoSync.syncNow(); ok() }
            "library", "watched", "unwatched", "forget" -> thisAction(cmd, a)
            else -> fail("unknown command $cmd")
        }
    }

    /** "This" = explicit id/type, else what's playing, else the open details page. */
    private suspend fun thisAction(cmd: String, a: JSONObject): JSONObject {
        val playing = player?.get()?.uiState?.value
        val (id, type) = when {
            a.optString("id").isNotBlank() -> a.optString("id") to a.optString("type", if (a.has("season")) "series" else "movie")
            currentDetails != null -> currentDetails!!
            else -> return fail("nothing on screen to act on - give id and type")
        }
        val kind = if (type == "movie") "movie" else "series"
        val meta = withContext(Dispatchers.IO) { chaoSync.cinemeta(kind, id) }
        val title = meta?.optString("name")?.takeIf { it.isNotBlank() } ?: playing?.contentName ?: id
        when (cmd) {
            "library" -> {
                val inLib = libraryRepository.isInLibrary(id, kind).first()
                val add = when (a.optString("action", "add")) { "remove" -> false; "toggle" -> !inLib; else -> true }
                if (add != inLib) {
                    libraryRepository.toggleDefault(com.nuvio.tv.domain.model.LibraryEntryInput(
                        itemId = id, itemType = kind, title = title,
                        poster = meta?.optString("poster")?.takeIf { it.isNotBlank() },
                        background = meta?.optString("background")?.takeIf { it.isNotBlank() },
                        logo = meta?.optString("logo")?.takeIf { it.isNotBlank() },
                        description = meta?.optString("description")?.takeIf { it.isNotBlank() },
                        releaseInfo = meta?.optString("releaseInfo")?.takeIf { it.isNotBlank() },
                    ))
                }
                toast(if (add) "Added $title to Library" else "Removed $title from Library")
                return ok(JSONObject().put("title", title).put("inLibrary", add))
            }
            "watched", "unwatched" -> {
                val season = if (a.has("season")) a.optInt("season") else null
                val episode = if (a.has("episode")) a.optInt("episode") else null
                val videoId = if (season != null && episode != null) "$id:$season:$episode" else id
                val what = if (season != null && episode != null) "$title S${season}E$episode" else title
                if (cmd == "watched") {
                    progressRepository.markAsCompleted(com.nuvio.tv.domain.model.WatchProgress(
                        contentId = id, contentType = kind, name = title,
                        poster = meta?.optString("poster")?.takeIf { it.isNotBlank() },
                        backdrop = meta?.optString("background")?.takeIf { it.isNotBlank() },
                        logo = meta?.optString("logo")?.takeIf { it.isNotBlank() },
                        videoId = videoId, season = season, episode = episode, episodeTitle = null,
                        position = 1L, duration = 1L, lastWatched = System.currentTimeMillis()
                    ))
                } else {
                    progressRepository.removeFromHistory(id, videoId, season, episode)
                }
                toast(if (cmd == "watched") "Marked $what watched" else "Marked $what unwatched")
                return ok(JSONObject().put("title", what))
            }
            else -> {
                progressRepository.removeProgress(id)
                toast("Removed $title from Continue Watching")
                return ok(JSONObject().put("title", title))
            }
        }
    }

    private suspend fun openUri(uri: String) = withContext(Dispatchers.Main) {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri), context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }

    private fun toast(text: String) = main.post { Toast.makeText(context, text, Toast.LENGTH_LONG).show() }

    companion object {
        private const val TAG = "ChaoLink"
        /** Set by MainActivity's nav listener / the details and player screens. */
        @Volatile var currentRoute: String? = null
        @Volatile var currentDetails: Pair<String, String>? = null
        @Volatile var player: WeakReference<PlayerViewModel>? = null
        @Volatile var navigate: ((String) -> Unit)? = null
        @Volatile private var appContext: Context? = null

        /** The TV's own name (Settings > System > About > Device name), e.g. "Master Bedroom". */
        fun deviceName(): String =
            appContext?.let { ctx -> runCatching { Settings.Global.getString(ctx.contentResolver, "device_name") }.getOrNull() }
                ?.takeIf { it.isNotBlank() } ?: Build.MODEL ?: "Google TV"
    }
}
