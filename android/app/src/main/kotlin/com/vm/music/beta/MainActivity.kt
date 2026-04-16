package com.vm.music.beta

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var songShareChannel: MethodChannel? = null
    private var pendingSharedSong: HashMap<String, Any?>? = null

    companion object {
        private const val SONG_SHARE_CHANNEL = "com.vm.music.beta/song_share"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        songShareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SONG_SHARE_CHANNEL
        )
        songShareChannel?.setMethodCallHandler { call, result ->
            if (call.method == "consumePendingSharedSong") {
                result.success(pendingSharedSong)
                pendingSharedSong = null
            } else {
                result.notImplemented()
            }
        }
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        val payload = parseSharedSongIntent(intent) ?: return
        pendingSharedSong = payload
        songShareChannel?.invokeMethod("onSharedSongReceived", payload)
    }

    private fun parseSharedSongIntent(intent: Intent): HashMap<String, Any?>? {
        val action = intent.action ?: return null
        val uri: Uri? = when (action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        }
        if (uri == null) return null
        if (uri.scheme.equals("vmmusic", ignoreCase = true) &&
            uri.host.equals("song", ignoreCase = true)) {
            val videoId = (uri.getQueryParameter("videoId") ?: "").trim()
            if (videoId.isEmpty()) return null
            val payload = HashMap<String, Any?>()
            payload["videoId"] = videoId
            payload["title"] = (uri.getQueryParameter("title") ?: "").trim()
            payload["artist"] = (uri.getQueryParameter("artist") ?: "").trim()
            payload["thumbnailUrl"] = (uri.getQueryParameter("thumbnailUrl") ?: "").trim()
            val durationMs = (uri.getQueryParameter("durationMs") ?: "").toLongOrNull()
            if (durationMs != null && durationMs > 0) {
                payload["durationMs"] = durationMs
            }
            payload["timestampMs"] = System.currentTimeMillis()
            return payload
        }
        val json = readUriAsJson(uri) ?: return null
        val type = json.optString("type", "").trim()
        if (type.isNotEmpty() && type != "vm_music_song") return null
        val videoId = json.optString("videoId", "").trim()
        if (videoId.isEmpty()) return null

        val payload = HashMap<String, Any?>()
        payload["videoId"] = videoId
        payload["title"] = json.optString("title", "").trim()
        payload["artist"] = json.optString("artist", "").trim()
        payload["thumbnailUrl"] = json.optString("thumbnailUrl", "").trim()
        if (json.has("durationMs")) {
            payload["durationMs"] = json.optLong("durationMs", 0L)
        }
        payload["timestampMs"] = System.currentTimeMillis()
        return payload
    }

    private fun readUriAsJson(uri: Uri): JSONObject? {
        return try {
            contentResolver.openInputStream(uri)?.use { stream ->
                val text = stream.bufferedReader().use { it.readText() }
                JSONObject(text)
            }
        } catch (_: Exception) {
            null
        }
    }
}
