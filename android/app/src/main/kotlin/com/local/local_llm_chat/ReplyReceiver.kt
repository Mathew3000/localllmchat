package com.local.local_llm_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

/**
 * Receives the voice reply from Android Auto (or wearables).
 *
 * Forwards the text to [MainActivity] via the stored MethodChannel reference
 * so Flutter's AppProvider can send it as a new chat message.
 * Also cancels the notification after handling.
 */
class ReplyReceiver : BroadcastReceiver() {

    companion object {
        /** Set to true in the read-pending intent (no reply text expected). */
        const val EXTRA_READ = "extra_read"
    }

    override fun onReceive(context: Context, intent: Intent) {
        // ── Mark-as-read path ─────────────────────────────────────────────────
        if (intent.getBooleanExtra(EXTRA_READ, false)) {
            AutoNotificationHelper.cancel(context)
            return
        }

        // ── Voice reply path ──────────────────────────────────────────────────
        val bundle = RemoteInput.getResultsFromIntent(intent)
        val replyText = bundle?.getCharSequence(AutoNotificationHelper.KEY_REPLY)
            ?.toString()?.trim()
            ?: return  // Nothing to forward

        if (replyText.isEmpty()) return

        // Cancel the notification immediately so Auto doesn't repeat it
        AutoNotificationHelper.cancel(context)

        // Deliver reply to Flutter via the MethodChannel stored on MainActivity
        MainActivity.autoChannel?.invokeMethod("onAutoReply", replyText)
    }
}
