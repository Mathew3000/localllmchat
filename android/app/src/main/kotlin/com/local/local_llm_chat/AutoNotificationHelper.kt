package com.local.local_llm_chat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput

/**
 * Posts and cancels the Android Auto / wearable-compatible MessagingStyle
 * notification that lets the car read the latest LLM reply aloud and lets
 * the driver respond by voice.
 *
 * Android Auto 2.0+ picks up CATEGORY_MESSAGE notifications with
 * MessagingStyle automatically — no CarExtender needed.
 */
object AutoNotificationHelper {

    private const val CHANNEL_ID     = "loom_auto_messages"
    private const val NOTIFICATION_ID = 7001
    private const val BOT_NAME       = "LoomChat"
    /** Remote-input key used by Android Auto to deliver the voice reply. */
    const val KEY_REPLY              = "key_auto_reply"
    /** Maximum characters posted to the car display / TTS engine. */
    private const val MAX_TEXT_LEN   = 500

    // ── Channel creation (safe to call repeatedly) ────────────────────────────

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "LoomChat Auto Messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "LLM replies readable in Android Auto"
                setSound(null, null)
                enableVibration(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    // ── Post ──────────────────────────────────────────────────────────────────

    /**
     * @param senderName  Display name for the user (shown as conversation context).
     * @param userText    The user's last message (optional context bubble).
     * @param replyText   The LLM's reply — this is what Auto reads aloud.
     * @param timestamp   Unix epoch millis; defaults to now.
     */
    fun postMessage(
        context: Context,
        senderName: String,
        userText: String,
        replyText: String,
        timestamp: Long,
    ) {
        ensureChannel(context)

        val truncated = if (replyText.length > MAX_TEXT_LEN)
            replyText.take(MAX_TEXT_LEN) + "…"
        else replyText

        // ── Persons ───────────────────────────────────────────────────────────
        val botPerson  = Person.Builder().setName(BOT_NAME).setBot(true).build()
        val userPerson = Person.Builder().setName(senderName.ifBlank { "You" }).build()

        // ── MessagingStyle ────────────────────────────────────────────────────
        val style = NotificationCompat.MessagingStyle(botPerson)
        style.conversationTitle = BOT_NAME
        style.isGroupConversation = false
        if (userText.isNotBlank() && senderName.isNotBlank()) {
            style.addMessage(userText, timestamp - 1L, userPerson)
        }
        style.addMessage(truncated, timestamp, botPerson)

        // ── RemoteInput (voice reply) ─────────────────────────────────────────
        val remoteInput = RemoteInput.Builder(KEY_REPLY)
            .setLabel("Reply")
            .build()

        val replyIntent = Intent(context, ReplyReceiver::class.java)
        val replyPending = PendingIntent.getBroadcast(
            context,
            NOTIFICATION_ID,
            replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

        val replyAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Reply",
            replyPending,
        )
            .addRemoteInput(remoteInput)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .build()

        // ── Tap action: open the app ──────────────────────────────────────────
        val openIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply { addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP) }
            ?: Intent()
        val openPending = PendingIntent.getActivity(
            context, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // ── Notification ──────────────────────────────────────────────────────
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setStyle(style)
            .addAction(replyAction)
            .setContentIntent(openPending)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
    }

    // ── Cancel ────────────────────────────────────────────────────────────────

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }
}
