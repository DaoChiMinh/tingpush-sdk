package com.tingpush.sdk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import java.util.concurrent.ConcurrentHashMap

/**
 * Hiển thị cuộc gọi đến: notification CallStyle + full-screen intent (màn hình cuộc gọi khi máy khoá),
 * nhạc chuông lặp (FLAG_INSISTENT) cho tới khi nghe / từ chối / hết giờ.
 */
internal object CallNotifier {
    private const val CHANNEL_CALL = "tingpush_incoming_call"
    private const val CHANNEL_MISSED = "tingpush_missed_call"
    private const val CHANNEL_DEFAULT = "tingpush_default"

    private val handler = Handler(Looper.getMainLooper())

    /** Cuộc gọi đang đổ chuông, theo call id. */
    private val ringing = ConcurrentHashMap<String, CallInfo>()

    /** Cuộc gọi đã nghe (để báo onCallEnded khi server gửi call_ended). */
    private val answered = ConcurrentHashMap.newKeySet<String>()

    /** call_ended tới trước incoming_call (mạng chậm): không đổ chuông nữa. */
    private val endedBeforeShown = ConcurrentHashMap.newKeySet<String>()

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val texts = TingPush.options.callTexts
        val manager = context.getSystemService(NotificationManager::class.java)

        val ringtone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val callChannel = NotificationChannel(CHANNEL_CALL, texts.callChannelName, NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(
                ringtone,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 1000, 1000)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(callChannel)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_MISSED, texts.missedChannelName, NotificationManager.IMPORTANCE_DEFAULT)
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_DEFAULT, texts.notificationChannelName, NotificationManager.IMPORTANCE_HIGH)
        )
    }

    fun showIncoming(context: Context, call: CallInfo) {
        if (endedBeforeShown.remove(call.id)) return
        if (ringing.putIfAbsent(call.id, call) != null) return // push trùng
        val texts = TingPush.options.callTexts
        val id = notificationId(call.id)

        val person = Person.Builder()
            .setName(call.callerName.ifBlank { call.handle.ifBlank { "?" } })
            .setImportant(true)
            .build()

        val fullScreen = PendingIntent.getActivity(
            context, id,
            IncomingCallActivity.intent(context, call, IncomingCallActivity.ACTION_SHOW),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val answer = PendingIntent.getActivity(
            context, id + 1,
            IncomingCallActivity.intent(context, call, IncomingCallActivity.ACTION_ACCEPT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val decline = PendingIntent.getBroadcast(
            context, id + 2,
            Intent(context, CallActionReceiver::class.java)
                .setAction(CallActionReceiver.ACTION_DECLINE)
                .putExtra(CallInfo.EXTRA_CALL, call.toBundle()),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_CALL)
            .setSmallIcon(smallIcon(context))
            .setContentTitle(call.callerName.ifBlank { call.handle })
            .setContentText(if (call.isVideo) texts.incomingVideo else texts.incomingAudio)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(fullScreen)
            .setFullScreenIntent(fullScreen, true)
            .setTimeoutAfter(call.timeoutSeconds * 1000L)
            .setStyle(NotificationCompat.CallStyle.forIncomingCall(person, decline, answer).setIsVideo(call.isVideo))
            .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)) // Android < 8
            .setVibrate(longArrayOf(0, 1000, 1000))
        TingPush.options.notificationColor?.let { builder.setColor(it) }

        val notification = builder.build()
        notification.flags = notification.flags or Notification.FLAG_INSISTENT // lặp chuông tới khi huỷ
        notify(context, id, notification)
        TingPush.post { it.onIncomingCall(call) }

        handler.postDelayed({
            if (ringing.containsKey(call.id)) missed(context, call)
        }, call.timeoutSeconds * 1000L)
    }

    /** Người dùng bấm Nghe. */
    fun accepted(context: Context, call: CallInfo) {
        if (ringing.remove(call.id) == null) return
        answered.add(call.id)
        cancel(context, call.id)
    }

    /** Người dùng bấm Từ chối. */
    fun declined(context: Context, call: CallInfo) {
        if (ringing.remove(call.id) == null) return
        cancel(context, call.id)
        TingPush.post { it.onCallDeclined(call) }
    }

    /** Server gửi call_ended: người gọi huỷ, máy khác đã nghe, hoặc đầu bên kia cúp máy. */
    fun remoteEnded(context: Context, callId: String, title: String?, body: String?) {
        val call = ringing[callId]
        when {
            call != null -> missed(context, call, title, body)
            answered.remove(callId) -> TingPush.post { it.onCallEnded(callId) }
            else -> endedBeforeShown.add(callId)
        }
    }

    /** App tự tắt cuộc gọi (TingPush.endCall). */
    fun dismiss(context: Context, callId: String) {
        ringing.remove(callId)
        answered.remove(callId)
        cancel(context, callId)
    }

    private fun missed(context: Context, call: CallInfo, title: String? = null, body: String? = null) {
        if (ringing.remove(call.id) == null) return
        cancel(context, call.id)
        TingPush.post { it.onCallMissed(call) }

        if (TingPush.options.showMissedCallNotification) {
            val texts = TingPush.options.callTexts
            val missedTitle = title ?: texts.missedCall
            val missedBody = body ?: call.callerName.ifBlank { call.handle }
            val notification = NotificationCompat.Builder(context, CHANNEL_MISSED)
                .setSmallIcon(smallIcon(context))
                .setContentTitle(missedTitle)
                .setContentText(missedBody)
                .setCategory(NotificationCompat.CATEGORY_MISSED_CALL)
                .setAutoCancel(true)
                .setContentIntent(openAppIntent(context, missedTitle, missedBody, call.data, notificationId(call.id) + 3))
                .build()
            notify(context, notificationId(call.id) + 3, notification)
        }
    }

    /** Thông báo thường khi app đang mở. */
    fun showNotification(context: Context, title: String?, body: String?, data: Map<String, String>) {
        val id = (System.currentTimeMillis() and 0x7fffffff).toInt()
        val builder = NotificationCompat.Builder(context, CHANNEL_DEFAULT)
            .setSmallIcon(smallIcon(context))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(context, title, body, data, id))
        TingPush.options.notificationColor?.let { builder.setColor(it) }
        notify(context, id, builder.build())
    }

    private fun cancel(context: Context, callId: String) {
        NotificationManagerCompat.from(context).cancel(notificationId(callId))
        IncomingCallActivity.finishCall(callId)
    }

    private fun openAppIntent(
        context: Context, title: String?, body: String?, data: Map<String, String>, requestCode: Int,
    ): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        for ((key, value) in data) launch.putExtra(key, value)
        launch.putExtra(TingPush.EXTRA_OPENED, true)
        title?.let { launch.putExtra(TingPush.EXTRA_TITLE, it) }
        body?.let { launch.putExtra(TingPush.EXTRA_BODY, it) }
        return PendingIntent.getActivity(
            context, requestCode, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun notify(context: Context, id: Int, notification: Notification) {
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (e: SecurityException) {
            // Chưa được cấp quyền POST_NOTIFICATIONS (Android 13+).
            TingPush.log("Không hiện được thông báo: ${e.message}")
            TingPush.notifyError(e)
        }
    }

    private fun smallIcon(context: Context): Int =
        TingPush.options.notificationIcon.takeIf { it != 0 } ?: context.applicationInfo.icon

    /** Mỗi cuộc gọi dùng 4 id liền nhau: thông báo, nghe, từ chối, cuộc gọi nhỡ. */
    private fun notificationId(callId: String): Int = (callId.hashCode() and 0x0fffffff) * 4
}
