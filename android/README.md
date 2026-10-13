# TingPush SDK cho Android (Kotlin / Java)

Yêu cầu: minSdk 23, compileSdk 35+, Kotlin 2.x và Firebase Cloud Messaging. SDK là một module thư viện Android (`tingpush`).

## 1. Cài đặt

1. Nếu app chưa dùng Firebase:
   - Tạo project trên [Firebase Console](https://console.firebase.google.com) và thêm app Android.
   - Tải `google-services.json` về và đặt vào `app/`.
   - Thêm plugin `com.google.gms.google-services` vào project.
2. Trên TingPush, upload **service account JSON** của **cùng project Firebase** đó.
3. Thêm SDK từ [JitPack](https://jitpack.io/#DaoChiMinh/tingpush-sdk):

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}
```

```kotlin
// app/build.gradle.kts
dependencies {
    implementation("com.github.DaoChiMinh:tingpush-sdk:1.1.1")
}
```

SDK đã khai báo sẵn trong manifest: các quyền cần thiết, `FirebaseMessagingService` và màn hình cuộc gọi. Bạn không cần sửa `AndroidManifest.xml` của app.

## 2. Khởi tạo trong Application

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        TingPush.init(
            this,
            appId = "APP_ID_CUA_BAN",
            options = TingPush.Options(
                notificationIcon = R.drawable.ic_notification,  // icon trắng trong suốt
                callTexts = CallTexts(answer = "Nghe", decline = "Từ chối"),
                loggingEnabled = BuildConfig.DEBUG,
            ),
        )
        // Gán listener ở đây để không lỡ sự kiện khi app được FCM đánh thức lúc đang tắt.
        TingPush.listener = object : TingPushListener {
            override fun onCallAccepted(call: CallInfo) {
                // Người dùng bấm Nghe → kết nối cuộc gọi thật (WebRTC/SIP…) bằng call.id, call.data["room"].
            }
            override fun onCallDeclined(call: CallInfo) { /* báo server huỷ phía người gọi */ }
            override fun onCallMissed(call: CallInfo) { }
            override fun onCallEnded(callId: String) { /* đầu bên kia cúp máy */ }
            // Người dùng bấm thông báo (app đang mở, chạy nền hay đã tắt).
            override fun onNotificationOpened(notification: TingPushNotification) {
                /* điều hướng theo notification.data["screen"] */
            }
            // Thông báo tới khi app đang mở (SDK vẫn hiện, tắt bằng showNotificationsInForeground = false).
            override fun onNotificationReceived(notification: TingPushNotification) { }
            override fun onError(error: Throwable) { Log.e("Push", "lỗi", error) }
        }
    }
}
```

`serverUrl` mặc định là `https://tingpush.com`. Chỉ truyền khi tự host server TingPush hoặc test với server khác (vd server dev trong mạng LAN).

Khai báo `android:name=".App"` trong thẻ `<application>` của manifest.

**Java:** dùng `TingPush.init(this, "APP_ID")` và `TingPush.INSTANCE.setListener(...)`.

## 3. Activity chính

```kotlin
class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        TingPush.requestNotificationPermission(this)   // Android 13+
        TingPush.handleIntent(intent)                  // mở app từ thông báo / bấm Nghe
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        TingPush.handleIntent(intent)
    }
}
```

Khi người dùng bấm **Nghe**:

1. SDK mở activity khởi chạy (launcher) của app.
2. `handleIntent` phát sự kiện `onCallAccepted`.
3. Nếu máy đang khoá có mật khẩu, người dùng được yêu cầu mở khoá trước.

## 4. Gắn user và tag

```kotlin
TingPush.login("user-123")          // sau khi đăng nhập
TingPush.logout()                   // khi đăng xuất
TingPush.setTags(mapOf("plan" to "vip"))
TingPush.unsubscribe()              // ngừng nhận; subscribe() để nhận lại
TingPush.deviceId                   // ID thiết bị trên TingPush
TingPush.endCall(callId)            // tắt màn hình đổ chuông từ app
```

## 5. Để cuộc gọi đổ chuông ổn định

Nên có một màn hình "Cài đặt nhận cuộc gọi" trong app, giống Zalo:

```kotlin
// Android 14+: quyền hiện cuộc gọi toàn màn hình khi máy khoá.
if (!TingPush.canUseFullScreenIntent(this)) TingPush.openFullScreenIntentSettings(this)

// Tắt tối ưu pin cho app.
if (!TingPush.isIgnoringBatteryOptimizations(this)) TingPush.openBatteryOptimizationSettings(this)
```

- **Xiaomi, Oppo, Vivo, Realme:** hướng dẫn người dùng bật **Tự khởi động (Autostart)** và khoá app trong đa nhiệm. Mỗi hãng có trang cài đặt riêng.
- **Google Play và quyền `USE_FULL_SCREEN_INTENT`:** từ Android 14, Play chỉ tự cấp quyền này cho app có chức năng chính là gọi điện hoặc báo thức. Khi khai báo trên Play Console, chọn mục đích sử dụng phù hợp. Nếu không được cấp, cuộc gọi vẫn hiện dạng heads-up kèm chuông, nhưng không bật toàn màn hình khi máy khoá.

## 6. App đã có FirebaseMessagingService riêng

Mỗi app chỉ có một service nhận FCM. Có hai bước:

**Bước 1.** Cho service của bạn kế thừa SDK:

```kotlin
class MyMessagingService : TingPushMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)   // SDK xử lý push của TingPush
        // xử lý thêm của bạn…
    }
    override fun onNewToken(token: String) {
        super.onNewToken(token)
    }
}
```

**Bước 2.** Trong manifest của app, khai báo service của bạn và gỡ service của SDK:

```xml
<service android:name="com.tingpush.sdk.TingPushMessagingService" tools:node="remove" />
<service android:name=".MyMessagingService" android:exported="false">
    <intent-filter><action android:name="com.google.firebase.MESSAGING_EVENT" /></intent-filter>
</service>
```

## Kiểm tra nhanh

1. Chạy app trên máy thật hoặc emulator có Google Play. Logcat phải có `TingPush: Đã đăng ký thiết bị …`.
2. Trên TingPush, tab *Gửi thông báo*, chọn **📞 Cuộc gọi**, gửi tới thiết bị.
3. Thử khi app đang mở, khi đã vuốt tắt app, và khi màn hình đang khoá.
