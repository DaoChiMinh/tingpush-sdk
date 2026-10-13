# TingPush SDK cho Flutter

Plugin Flutter dựa trên các thư viện sau:

- [`firebase_messaging`](https://pub.dev/packages/firebase_messaging): lấy token và nhận push.
- [`flutter_callkit_incoming`](https://pub.dev/packages/flutter_callkit_incoming): màn hình cuộc gọi, dùng CallKit trên iOS và màn hình toàn màn hình trên Android.

Phần native nhỏ trong plugin lo những việc trước đây app phải tự làm: nhận VoIP push trên iOS (không cần sửa `AppDelegate`) và hiện thông báo khi app đang mở trên Android.

Yêu cầu Flutter 3.22+, iOS 15+, Android minSdk 24.

## 1. Cài đặt

```yaml
# pubspec.yaml của app
dependencies:
  firebase_core: ^4.0.0
  tingpush:
    path: ./TingPushSDK/flutter/tingpush   # hoặc git: url của repo nội bộ
```

Cấu hình Firebase cho app bằng [FlutterFire CLI](https://firebase.google.com/docs/flutter/setup): chạy `flutterfire configure`. Lệnh này tạo `firebase_options.dart`. Sau đó:

- **Android:** trên TingPush, upload service account JSON của **cùng project Firebase**.
- **iOS:** trên TingPush, upload key `.p8` của Apple. Server gửi thẳng tới APNs, không đi qua FCM.

## 2. Khởi tạo (`main.dart`)

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:tingpush/tingpush.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await TingPush.initialize(
    appId: 'APP_ID_CUA_BAN',
    serverUrl: 'https://push.example.com',
    callStyle: const TingPushCallStyle(appName: 'MyApp', textAccept: 'Nghe', textDecline: 'Từ chối'),
    logging: true,
  );

  runApp(const MyApp());
}
```

`initialize` tự đăng ký handler nền (`FirebaseMessaging.onBackgroundMessage`) để đổ chuông khi app đang tắt. App đã có handler nền riêng thì truyền `handleBackgroundMessages: false` và gọi `TingPush.handleBackgroundMessage(message)` trong handler đó.

Các tuỳ chọn khác của `initialize`:

| Tham số | Mặc định | Ý nghĩa |
|---|---|---|
| `requestPermission` | `true` | Xin quyền thông báo ngay (iOS, Android 13+). |
| `showNotificationsInForeground` | `true` | Vẫn hiện thông báo khi app đang mở. |
| `iosSandbox` | debug/profile = sandbox, release = production | Bản release cài từ Xcode bằng profile development thì truyền `true`. |

## 3. Nhận sự kiện

Gắn ở đâu cũng được, vd `initState` của màn hình gốc. Sự kiện xảy ra trước khi gắn (bấm thông báo làm app mở lên, bấm Nghe lúc app đang tắt) được giữ lại và gửi ngay cho listener đầu tiên.

```dart
// Người dùng bấm vào thông báo: app đang mở, chạy nền hay đã tắt đều vào đây.
TingPush.onNotificationOpened.listen((n) {
  // điều hướng theo n.data['screen']...
});

// Nhận thông báo khi app đang mở (SDK vẫn hiện banner, tắt bằng showNotificationsInForeground: false).
TingPush.onNotificationReceived.listen((n) {
  // n.title, n.body, n.data
});

TingPush.onCallEvent.listen((e) {
  switch (e.action) {
    case TingPushCallAction.accepted:
      // Người dùng bấm Nghe → kết nối cuộc gọi thật (WebRTC/SIP/Agora…) bằng e.call.id, e.call.data['room'].
      break;
    case TingPushCallAction.declined:
      // Báo server huỷ phía người gọi.
      break;
    case TingPushCallAction.ended:
    case TingPushCallAction.timeout:
    case TingPushCallAction.incoming:
      break;
  }
});

TingPush.onDeviceRegistered.listen((deviceId) { });
TingPush.onError.listen((error) { });
```

| Sự kiện | Khi nào |
|---|---|
| `onNotificationReceived` | Thông báo / data message tới khi app đang mở. |
| `onNotificationOpened` | Người dùng bấm thông báo (mọi trạng thái app). |
| `onCallEvent` | Cuộc gọi: `incoming`, `accepted`, `declined`, `ended`, `timeout`. |
| `onDeviceRegistered` | Đăng ký thiết bị với TingPush thành công. |
| `onError` | Lỗi đăng ký thiết bị. |

## 4. Gắn user và tag

```dart
await TingPush.login('user-123');     // sau khi đăng nhập
await TingPush.logout();              // khi đăng xuất
await TingPush.setTags({'plan': 'vip'});
await TingPush.unsubscribe();         // subscribe() để nhận lại
final id = await TingPush.deviceId;
await TingPush.endCall(callId);       // tắt cuộc gọi từ app (đầu bên kia cúp máy)
await TingPush.setCallConnected(callId); // iOS: bắt đầu đếm giờ gọi
```

## 5. Cấu hình iOS

Mở `ios/Runner.xcworkspace` bằng Xcode, vào *Signing & Capabilities*:

- Thêm **Push Notifications**.
- Thêm **Background Modes**, tick **Remote notifications** (và **Voice over IP** nếu dùng cuộc gọi).

Không cần sửa `AppDelegate.swift`: plugin tự đăng ký PushKit và báo CallKit khi có cuộc gọi. Nếu app đang có đoạn code PushKit chép từ bản hướng dẫn cũ, hãy xoá đi.

## 6. Cấu hình Android (cho cuộc gọi)

`flutter_callkit_incoming` đã khai báo sẵn quyền và màn hình cuộc gọi. Để màn hình app hiện được khi máy khoá sau khi bấm Nghe, thêm vào `android/app/src/main/AndroidManifest.xml`, trong `<activity android:name=".MainActivity">`:

```xml
android:showWhenLocked="true"
android:turnScreenOn="true"
```

**Android 14+:** kiểm tra và xin quyền hiện cuộc gọi toàn màn hình khi máy khoá.

```dart
if (!await TingPush.canUseFullScreenIntent()) {
  await TingPush.requestFullScreenIntentPermission();
}
```

Icon thông báo khi app đang mở lấy theo meta-data `com.google.firebase.messaging.default_notification_icon` (giống thông báo FCM), không có thì dùng icon app.

Với Xiaomi, Oppo và Vivo, xem mục *Lưu ý chung* trong [README tổng](../../README.md): bật Tự khởi động và tắt tối ưu pin.

## Kiểm tra nhanh

1. Chạy trên **máy thật**. Simulator iOS không nhận được VoIP push.
2. Bật `logging: true` và xem log `[TingPush] Đã đăng ký thiết bị …`.
3. Trên TingPush:
   - tab *Thiết bị*: máy iOS phải có badge **VoIP**;
   - tab *Gửi thông báo*: gửi thử khi app đang mở, chạy nền và đã tắt, bấm vào để kiểm tra `onNotificationOpened`;
   - chọn **📞 Cuộc gọi**, gửi thử khi app đang mở, khi đã tắt và khi máy khoá.
