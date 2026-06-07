package com.local.local_llm_chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput

/**
 * Posts and cancels the Android Auto / wearable-compatible MessagingStyle
 * notification that lets the car read the latest LLM reply aloud and lets
 * the driver respond by voice.
 */
object AutoNotificationHelper {

    private const val CHANNEL_ID   = "loom_auto_messages"
    private const val NOTIFICATION_ID = 7001
    private const val BOT_NAME     = "LoomChat"
    /** Remote-input key used by Android Auto to deliver the voice reply. */
    const val KEY_REPLY            = "key_auto_reply"
    /** Maximum characters posted to the car display / TTS engine. */
    private const val MAX_TEXT_LEN = 500

    // ── Channel creation (safe to call repeatedly) ────────────────────────────

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "LoomChat Auto Messages",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "LLM replies readable in Android Auto"
                setSound(null, null)   // silence on phone; Auto handles audio
                enableVibration(false)
            }
            context.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    // ── Post ──────────────────────────────────────────────────────────────────

    /**
     * @param senderName  Display name for the user message shown in the
     *                    conversation (optional; pass empty to skip).
     * @param userText    The user's last message (shown as conversation context).
     * @param replyText   The LLM's reply — this is what Auto reads aloud.
     * @param timestamp   Unix epoch millis.
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

        // ── MessagingStyle ────────────────────────────────────────────────────
        val style = NotificationCompat.MessagingStyle(BOT_NAME).apply {
            conversationTitle = BOT_NAME
            isGroupConversation = false

            // Show the user's question as context if provided
            if (userText.isNotBlank() && senderName.isNotBlank()) {
                addMessage(
                    NotificationCompat.MessagingStyle.Message(
                        userText, timestamp - 1, senderName
                    )
                )
            }
            // The LLM reply — Auto reads this aloud
            addMessage(
                NotificationCompat.MessagingStyle.Message(
                    truncated, timestamp, BOT_NAME
                )
            )
        }

        // ── Tap action: open the app ──────────────────────────────────────────
        val openIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply { addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP) }
        val openPending = PendingIntent.getActivity(
            context, 0, openIntent ?: Intent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setStyle(style)
            .addAction(replyAction)
            .setContentIntent(openPending)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            // Android Auto requires that Car-Extensions allow the reply action
            .extend(
                NotificationCompat.CarExtender()
                    .setUnreadConversation(
                        buildCarConversation(context, truncated, timestamp, replyPending, remoteInput)
                    )
            )
            .build()

        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
    }

    // ── Cancel ────────────────────────────────────────────────────────────────

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    @Suppress("DEPRECATION") // CarExtender.UnreadConversation is the correct API for Auto messaging
    private fun buildCarConversation(
        context: Context,
        text: String,
        timestamp: Long,
        replyPending: PendingIntent,
        remoteInput: RemoteInput,
    ): NotificationCompat.CarExtender.UnreadConversation {
        return NotificationCompat.CarExtender.UnreadConversation.Builder(BOT_NAME)
            .addMessage(text)
            .setLatestTimestamp(timestamp)
            .setReadPendingIntent(
                PendingIntent.getBroadcast(
                    context,
                    NOTIFICATION_ID + 1,
                    Intent(context, ReplyReceiver::class.java)
                        .putExtra(ReplyReceiver.EXTRA_READ, true),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )
            .setReplyAction(replyPending, remoteInput)
            .build()
    }
}
