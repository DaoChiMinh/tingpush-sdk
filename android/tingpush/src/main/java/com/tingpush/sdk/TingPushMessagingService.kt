package com.tingpush.sdk

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Nhận push từ FCM. Đã khai báo sẵn trong AndroidManifest của SDK.
 *
 * Nếu app có FirebaseMessagingService riêng (vd dùng thêm thư viện khác), hãy kế thừa class này và gọi super,
 * rồi khai báo service của app trong manifest thay cho service này (xem README).
 */
open class TingPushMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        TingPush.onNewToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        when (data["type"]) {
            "incoming_call" -> {
                // Server đặt TTL = thời gian đổ chuông nên FCM không giao cuộc gọi đã quá hạn.
                val call = CallInfo.fromData(data) ?: return
                CallNotifier.showIncoming(this, call)
            }
            "call_ended" -> {
                val callId = data["call_id"] ?: return
                CallNotifier.remoteEnded(this, callId, data["title"], data["body"])
            }
            else -> {
                val notification = message.notification
                // Có khối notification: app ở nền thì FCM tự hiện; tới đây nghĩa là app đang mở.
                if (notification != null && TingPush.options.showNotificationsInForeground) {
                    CallNotifier.showNotification(this, notification.title, notification.body, data)
                }
                val received = TingPushNotification(notification?.title, notification?.body, data)
                TingPush.post { it.onNotificationReceived(received) }
            }
        }
    }
}
