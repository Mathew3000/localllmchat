package com.local.local_llm_chat

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val STREAMING_CHANNEL  = "com.local.local_llm_chat/streaming"
        private const val AUTO_CHANNEL       = "com.local.local_llm_chat/android_auto"

        /**
         * Kept here so [ReplyReceiver] can forward voice replies to Flutter
         * without needing a Context → Activity lookup.
         * Null when the engine is not running.
         */
        @JvmStatic
        var autoChannel: MethodChannel? = null
            private set
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Streaming keep-alive service channel ─────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STREAMING_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, StreamingService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, StreamingService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ── Android Auto channel ──────────────────────────────────────────────
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUTO_CHANNEL,
        )
        autoChannel = channel
        AutoNotificationHelper.ensureChannel(this)

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "postMessage" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = call.arguments as? Map<String, Any> ?: emptyMap()
                    AutoNotificationHelper.postMessage(
                        context     = this,
                        senderName  = args["senderName"]  as? String ?: "You",
                        userText    = args["userText"]    as? String ?: "",
                        replyText   = args["replyText"]   as? String ?: "",
                        timestamp   = (args["timestamp"]  as? Number)?.toLong()
                                        ?: System.currentTimeMillis(),
                    )
                    result.success(null)
                }
                "cancel" -> {
                    AutoNotificationHelper.cancel(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        autoChannel = null
        super.onDestroy()
    }

    /**
     * Android Auto voice replies arrive here when the app is in the
     * foreground (singleTop re-delivery).  Background replies go directly
     * to [ReplyReceiver], which calls [autoChannel] if the engine is alive.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Nothing extra needed — ReplyReceiver handles the RemoteInput bundle.
    }
}
