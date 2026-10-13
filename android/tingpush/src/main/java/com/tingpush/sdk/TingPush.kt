package com.tingpush.sdk

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.annotation.DrawableRes
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Điểm vào của SDK.
 *
 * ```kotlin
 * class App : Application() {
 *     override fun onCreate() {
 *         super.onCreate()
 *         TingPush.init(this, appId = "…")
 *     }
 * }
 * ```
 */
object TingPush {
    /** Địa chỉ server TingPush mặc định. */
    const val DEFAULT_SERVER_URL = "https://tingpush.com"

    private const val TAG = "TingPush"
    private const val PREFS = "com.tingpush.sdk"
    private const val KEY_DEVICE_ID = "deviceId"
    private const val KEY_USER_ID = "externalUserId"
    private const val KEY_FCM_TOKEN = "fcmToken"
    private const val KEY_PENDING_TAGS = "pendingTags"
    private const val KEY_UNSUBSCRIBED = "unsubscribed"

    /** Extra đánh dấu intent mở app từ thông báo do SDK tự hiển thị. */
    internal const val EXTRA_OPENED = "com.tingpush.sdk.OPENED"
    internal const val EXTRA_ACCEPTED = "com.tingpush.sdk.ACCEPTED"
    internal const val EXTRA_TITLE = "com.tingpush.sdk.TITLE"
    internal const val EXTRA_BODY = "com.tingpush.sdk.BODY"

    class Options(
        /** Icon nhỏ trên thanh trạng thái (drawable trắng trong suốt). 0 = icon app. */
        @DrawableRes val notificationIcon: Int = 0,
        /** Màu nhấn của thông báo (ARGB), null = mặc định. */
        val notificationColor: Int? = null,
        val callTexts: CallTexts = CallTexts(),
        /** Hiện thông báo "Cuộc gọi nhỡ" khi hết giờ đổ chuông hoặc người gọi huỷ. */
        val showMissedCallNotification: Boolean = true,
        /** Hiện thông báo khi app đang mở (FCM không tự hiện trong trường hợp này). */
        val showNotificationsInForeground: Boolean = true,
        val loggingEnabled: Boolean = false,
    )

    /**
     * Nhận sự kiện. Nên gán trong Application.onCreate để không lỡ sự kiện khi app được FCM đánh thức.
     * Bấm thông báo / bấm Nghe trước khi gán listener thì sự kiện được giữ lại và gửi ngay khi gán.
     */
    @Volatile
    var listener: TingPushListener? = null
        set(value) {
            field = value
            if (value != null) flushPending()
        }

    /** Sự kiện mở thông báo / nghe cuộc gọi xảy ra khi chưa có listener. */
    private val pending = mutableListOf<(TingPushListener) -> Unit>()

    internal lateinit var appContext: Context
        private set
    internal var options = Options()
        private set

    private var api: TingPushApi? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val prefs: SharedPreferences by lazy { appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE) }

    /** ID thiết bị trên TingPush (có sau khi đăng ký thành công). */
    val deviceId: String? get() = if (::appContext.isInitialized) prefs.getString(KEY_DEVICE_ID, null) else null

    val externalUserId: String? get() = if (::appContext.isInitialized) prefs.getString(KEY_USER_ID, null) else null

    /**
     * Gọi trong Application.onCreate.
     * @param appId App ID của dự án trên TingPush.
     * @param serverUrl địa chỉ server TingPush; chỉ cần đổi khi tự host server hoặc test với server khác.
     */
    @JvmStatic
    @JvmOverloads
    fun init(context: Context, appId: String, serverUrl: String = DEFAULT_SERVER_URL, options: Options = Options()) {
        appContext = context.applicationContext
        this.options = options
        api = TingPushApi(serverUrl, appId)
        CallNotifier.createChannels(appContext)

        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { onNewToken(it) }
            .addOnFailureListener { notifyError(it) }
    }

    // ---------------- Người dùng ----------------

    /** Gắn thiết bị với user trong hệ thống của bạn (gọi sau khi đăng nhập). Backend gửi theo External ID này. */
    @JvmStatic
    fun login(externalUserId: String) {
        prefs.edit().putString(KEY_USER_ID, externalUserId).apply()
        sync()
    }

    /** Bỏ gắn user (gọi khi đăng xuất). */
    @JvmStatic
    fun logout() {
        prefs.edit().remove(KEY_USER_ID).apply()
        sync()
    }

    /** Thay toàn bộ tag của thiết bị (dùng để lọc khi gửi). emptyMap() = xoá hết tag. */
    @JvmStatic
    fun setTags(tags: Map<String, String>) {
        prefs.edit().putString(KEY_PENDING_TAGS, JSONObject(tags).toString()).apply()
        sync()
    }

    /** Ngừng nhận thông báo trên thiết bị này cho tới khi gọi [subscribe]. */
    @JvmStatic
    fun unsubscribe() {
        prefs.edit().putBoolean(KEY_UNSUBSCRIBED, true).apply()
        val id = deviceId ?: return
        executor.execute {
            runCatching { api?.unsubscribe(id) }.onFailure { notifyError(it) }
        }
    }

    @JvmStatic
    fun subscribe() {
        prefs.edit().putBoolean(KEY_UNSUBSCRIBED, false).apply()
        sync()
    }

    // ---------------- Mở app từ thông báo / cuộc gọi ----------------

    /**
     * Gọi trong onCreate và onNewIntent của Activity chính. Phát sự kiện [TingPushListener.onCallAccepted]
     * (người dùng bấm Nghe) hoặc [TingPushListener.onNotificationOpened]. Trả về true nếu intent đến từ SDK/FCM.
     */
    @JvmStatic
    fun handleIntent(intent: Intent?): Boolean {
        if (intent == null) return false
        if (intent.getBooleanExtra(EXTRA_ACCEPTED, false)) {
            intent.removeExtra(EXTRA_ACCEPTED)
            val call = CallInfo.fromIntent(intent) ?: return false
            deliver { it.onCallAccepted(call) }
            return true
        }
        val extras = intent.extras ?: return false
        // Thông báo do FCM tự hiện khi app ở nền có "google.message_id"; do SDK hiện thì có EXTRA_OPENED.
        if (!intent.getBooleanExtra(EXTRA_OPENED, false) && !extras.containsKey("google.message_id")) return false
        intent.removeExtra(EXTRA_OPENED)
        intent.removeExtra("google.message_id")
        val data = extras.keySet()
            .filterNot {
                it.startsWith("google.") || it.startsWith("gcm.") || it.startsWith("com.tingpush.sdk.") ||
                    it == "from" || it == "collapse_key"
            }
            .mapNotNull { key -> extras.getString(key)?.let { key to it } }
            .toMap()
        // Thông báo FCM tự hiện (app ở nền) không chuyển tiêu đề/nội dung vào intent nên title/body = null.
        val notification = TingPushNotification(extras.getString(EXTRA_TITLE), extras.getString(EXTRA_BODY), data)
        intent.removeExtra(EXTRA_TITLE)
        intent.removeExtra(EXTRA_BODY)
        deliver { it.onNotificationOpened(notification) }
        return true
    }

    /** Tắt màn hình đổ chuông / thông báo của cuộc gọi (vd đầu bên kia đã huỷ). */
    @JvmStatic
    fun endCall(callId: String) {
        CallNotifier.dismiss(appContext, callId)
    }

    // ---------------- Quyền & cài đặt ----------------

    /** Android 13+: xin quyền hiển thị thông báo. */
    @JvmStatic
    fun requestNotificationPermission(activity: Activity, requestCode: Int = 7301) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), requestCode)
        }
    }

    /** Android 14+: app có được hiện màn hình cuộc gọi toàn màn hình khi máy khoá không. */
    @JvmStatic
    fun canUseFullScreenIntent(context: Context): Boolean =
        Build.VERSION.SDK_INT < 34 ||
            context.getSystemService(NotificationManager::class.java).canUseFullScreenIntent()

    /** Mở trang cài đặt cho phép hiện toàn màn hình (Android 14+). */
    @JvmStatic
    fun openFullScreenIntentSettings(context: Context) {
        if (Build.VERSION.SDK_INT >= 34) {
            context.startActivity(
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    /** App đã được miễn tối ưu pin chưa (giúp nhận cuộc gọi ổn định trên Xiaomi, Oppo, Vivo…). */
    @JvmStatic
    fun isIgnoringBatteryOptimizations(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

    /** Mở trang cài đặt tối ưu pin của hệ thống để người dùng tắt cho app. */
    @JvmStatic
    fun openBatteryOptimizationSettings(context: Context) {
        context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    // ---------------- Nội bộ ----------------

    internal fun onNewToken(token: String) {
        log("FCM token: $token")
        prefs.edit().putString(KEY_FCM_TOKEN, token).apply()
        sync()
    }

    /** Đăng ký (upsert) thiết bị. Gọi lặp lại an toàn; chạy tuần tự trên 1 thread. */
    private fun sync() {
        executor.execute {
            val api = api ?: return@execute
            val token = prefs.getString(KEY_FCM_TOKEN, null) ?: return@execute
            if (prefs.getBoolean(KEY_UNSUBSCRIBED, false)) return@execute

            val tags = prefs.getString(KEY_PENDING_TAGS, null)
            val body = JSONObject()
                .put("platform", "Android")
                .put("token", token)
                // Server ghi đè externalUserId mỗi lần đăng ký nên luôn gửi giá trị hiện tại.
                .put("externalUserId", prefs.getString(KEY_USER_ID, null) ?: JSONObject.NULL)
                .put("appVersion", appVersion())
                .put("language", Locale.getDefault().language)
                .put("deviceModel", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
                .put("deviceOs", Build.VERSION.RELEASE)
            if (tags != null) body.put("tags", JSONObject(tags))

            try {
                val id = api.register(body)
                val editor = prefs.edit().putString(KEY_DEVICE_ID, id)
                // Tag đổi trong lúc đang gửi thì giữ lại để lần sync sau gửi tiếp.
                if (tags != null && prefs.getString(KEY_PENDING_TAGS, null) == tags) editor.remove(KEY_PENDING_TAGS)
                editor.apply()
                log("Đã đăng ký thiết bị $id")
                mainHandler.post { listener?.onDeviceRegistered(id) }
            } catch (e: Exception) {
                log("Đăng ký thiết bị lỗi: ${e.message}")
                notifyError(e)
            }
        }
    }

    private fun appVersion(): String = try {
        appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName.orEmpty()
    } catch (e: PackageManager.NameNotFoundException) {
        ""
    }

    /** Gửi cho listener; chưa có listener thì giữ lại tới khi gán. */
    private fun deliver(block: (TingPushListener) -> Unit) {
        val current = listener
        if (current != null) {
            block(current)
        } else {
            synchronized(pending) { pending.add(block) }
        }
    }

    private fun flushPending() {
        val events = synchronized(pending) { pending.toList().also { pending.clear() } }
        if (events.isNotEmpty()) mainHandler.post { listener?.let { l -> events.forEach { it(l) } } }
    }

    internal fun post(block: (TingPushListener) -> Unit) {
        mainHandler.post { listener?.let(block) }
    }

    internal fun notifyError(error: Throwable) = post { it.onError(error) }

    internal fun log(message: String) {
        if (options.loggingEnabled) Log.d(TAG, message)
    }
}
