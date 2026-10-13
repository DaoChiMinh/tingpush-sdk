package com.tingpush.sdk

import android.content.Intent
import android.os.Bundle

/** Thông tin cuộc gọi đọc từ payload push (giống nhau trên iOS và Android). */
data class CallInfo(
    /** call_id do server gửi (UUID). */
    val id: String,
    val callerName: String,
    val handle: String,
    val avatarUrl: String?,
    val isVideo: Boolean,
    /** Thời gian đổ chuông tối đa (giây). */
    val timeoutSeconds: Int,
    /** Toàn bộ payload, gồm cả các key "data" mà backend gửi kèm (vd room, token cuộc gọi…). */
    val data: Map<String, String>,
) {
    internal fun toBundle(): Bundle = Bundle().apply {
        for ((key, value) in data) putString(key, value)
    }

    companion object {
        internal const val DEFAULT_TIMEOUT_SECONDS = 45

        internal fun fromData(data: Map<String, String>): CallInfo? {
            val id = data["call_id"]?.takeIf { it.isNotBlank() } ?: return null
            return CallInfo(
                id = id,
                callerName = data["caller_name"].orEmpty(),
                handle = data["caller_handle"].orEmpty(),
                avatarUrl = data["caller_avatar"]?.takeIf { it.isNotBlank() },
                isVideo = data["is_video"] == "true",
                timeoutSeconds = data["timeout"]?.toIntOrNull() ?: DEFAULT_TIMEOUT_SECONDS,
                data = data,
            )
        }

        internal fun fromBundle(bundle: Bundle?): CallInfo? {
            if (bundle == null) return null
            val data = bundle.keySet().mapNotNull { key -> bundle.getString(key)?.let { key to it } }.toMap()
            return fromData(data)
        }

        internal fun fromIntent(intent: Intent?): CallInfo? = fromBundle(intent?.getBundleExtra(EXTRA_CALL))

        internal const val EXTRA_CALL = "com.tingpush.sdk.CALL"
    }
}

/** Thông báo nhận được / người dùng bấm vào. */
data class TingPushNotification(
    val title: String?,
    val body: String?,
    /** Các key "data" backend gửi kèm (vd screen, id…). */
    val data: Map<String, String>,
)

/**
 * Nhận sự kiện từ SDK. Mọi hàm đều có sẵn bản mặc định rỗng, chỉ cần override hàm cần dùng.
 * Luôn được gọi trên main thread.
 */
interface TingPushListener {
    /** Đăng ký thiết bị với server thành công. */
    fun onDeviceRegistered(deviceId: String) {}

    /** Nhận thông báo khi app đang mở, hoặc data message (silent push). */
    fun onNotificationReceived(notification: TingPushNotification) {}

    /**
     * Người dùng bấm vào thông báo, kể cả khi app đang tắt. Bấm trước khi gán [TingPush.listener] thì
     * sự kiện được giữ lại và gửi ngay khi gán.
     */
    fun onNotificationOpened(notification: TingPushNotification) {}

    /** Màn hình / thông báo cuộc gọi đến đã hiện (đang đổ chuông). */
    fun onIncomingCall(call: CallInfo) {}

    /** Người dùng bấm nghe (nhận qua [TingPush.handleIntent]): kết nối cuộc gọi (WebRTC/SIP…) tại đây. */
    fun onCallAccepted(call: CallInfo) {}

    /** Người dùng từ chối khi đang đổ chuông. */
    fun onCallDeclined(call: CallInfo) {}

    /** Hết thời gian đổ chuông, hoặc server báo call_ended trước khi nghe. */
    fun onCallMissed(call: CallInfo) {}

    /** Server báo call_ended cho cuộc gọi đã nghe (đầu bên kia cúp máy). */
    fun onCallEnded(callId: String) {}

    fun onError(error: Throwable) {}
}

/** Chữ hiển thị trên màn hình cuộc gọi. */
data class CallTexts(
    val incomingAudio: String = "Cuộc gọi thoại đến",
    val incomingVideo: String = "Cuộc gọi video đến",
    val answer: String = "Nghe",
    val decline: String = "Từ chối",
    val missedCall: String = "Cuộc gọi nhỡ",
    val callChannelName: String = "Cuộc gọi đến",
    val notificationChannelName: String = "Thông báo",
    val missedChannelName: String = "Cuộc gọi nhỡ",
)

class TingPushException(message: String) : Exception(message)
