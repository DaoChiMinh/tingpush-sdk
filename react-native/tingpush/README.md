# TingPush SDK cho React Native

SDK viết bằng TypeScript, dựa trên các thư viện sau:

- `@react-native-firebase/messaging`: lấy token và nhận push.
- `react-native-callkeep`: CallKit trên iOS, ConnectionService trên Android.
- `react-native-voip-push-notification`: VoIP push trên iOS.

Yêu cầu React Native 0.71+. SDK chưa hỗ trợ Expo Go; với Expo cần dùng development build và config plugin của từng thư viện.

## 1. Cài đặt

```bash
npm install @tingpush/react-native \
  @react-native-firebase/app @react-native-firebase/messaging \
  react-native-callkeep react-native-voip-push-notification \
  @react-native-async-storage/async-storage react-native-device-info
cd ios && pod install
```

Cấu hình Firebase theo [hướng dẫn của React Native Firebase](https://rnfirebase.io):

- **Android:** đặt `google-services.json` vào `android/app/`, rồi trên TingPush upload service account JSON của **cùng project Firebase**.
- **iOS:** đặt `GoogleService-Info.plist` vào project. Server gửi thẳng tới APNs, nên trên TingPush upload key `.p8`.

## 2. `index.js`: handler nền (Android)

Handler này phải đăng ký **trước** `AppRegistry`.

```js
import { AppRegistry } from 'react-native';
import TingPush from '@tingpush/react-native';
import App from './App';
import { name as appName } from './app.json';

// App ở nền hoặc đã tắt: hiện màn hình cuộc gọi đến (Android).
TingPush.registerBackgroundHandler();

AppRegistry.registerComponent(appName, () => App);
```

App đã có `setBackgroundMessageHandler` riêng thì không gọi `registerBackgroundHandler()`, mà gọi `await TingPush.handleBackgroundMessage(message)` trong handler của bạn.

Yêu cầu `@react-native-firebase/app` và `@react-native-firebase/messaging` bản 22 trở lên (SDK dùng API dạng hàm `getMessaging()`).

## 3. Khởi tạo trong component gốc

```tsx
import { useEffect } from 'react';
import TingPush from '@tingpush/react-native';

export default function App() {
  useEffect(() => {
    TingPush.initialize(
      {
        appId: 'APP_ID_CUA_BAN',
        appName: 'MyApp',
        logging: __DEV__,
      },
      {
        onCallEvent: ({ action, call }) => {
          if (action === 'accepted') {
            // Người dùng bấm Nghe → kết nối cuộc gọi thật (WebRTC/SIP…) bằng call.id, call.data.room.
          }
        },
        // Người dùng bấm thông báo (app đang mở, chạy nền hay đã tắt).
        onNotificationOpened: (n) => {
          /* điều hướng theo n.data.screen */
        },
        // Thông báo tới khi app đang mở: { title, body, data }.
        onNotificationReceived: (n) => { },
        onError: (e) => console.warn(e),
      },
    );

    // Android: người dùng bấm Nghe lúc app đang tắt.
    TingPush.getAcceptedCall().then((call) => {
      if (call) {
        /* kết nối cuộc gọi */
      }
    });
  }, []);
  // …
}
```

`serverUrl` mặc định là `https://tingpush.com`. Chỉ truyền khi tự host server TingPush hoặc test với server khác (vd server dev trong mạng LAN).

**Môi trường APNs:** mặc định `__DEV__` là sandbox. Bản TestFlight và App Store là production. Muốn chỉ định cố định thì truyền `iosSandbox`.

**Thông báo khi app đang mở:**

- iOS: hiện banner nếu `firebase.json` ở gốc project có:
  ```json
  { "react-native": { "messaging_ios_foreground_presentation_options": ["badge", "sound", "list", "banner"] } }
  ```
- Android: hệ thống không tự hiện. Dùng `onNotificationReceived` để hiển thị trong app (hoặc thư viện như notifee).

## 4. Gắn user và tag

```ts
await TingPush.login('user-123');      // sau khi đăng nhập
await TingPush.logout();               // khi đăng xuất
await TingPush.setTags({ plan: 'vip' });
await TingPush.unsubscribe();          // subscribe() để nhận lại
const deviceId = await TingPush.getDeviceId();
TingPush.endCall(callId);              // kết thúc cuộc gọi từ app
```

## 5. Cấu hình iOS (bắt buộc nếu dùng cuộc gọi)

1. Trong Xcode, vào *Signing & Capabilities*:
   - Thêm **Push Notifications**.
   - Thêm **Background Modes**, tick **Remote notifications** và **Voice over IP**.
2. Sửa `AppDelegate`. Trên iOS 13+, VoIP push **phải** được báo cho CallKit bằng code native ngay khi nhận.

Với `AppDelegate.mm` (Objective-C, React Native ≤ 0.76):

```objc
#import <PushKit/PushKit.h>
#import "RNCallKeep.h"
#import "RNVoipPushNotificationManager.h"

@interface AppDelegate () <PKPushRegistryDelegate>
@end

// Trong didFinishLaunchingWithOptions, trước return:
//   [RNVoipPushNotificationManager voipRegistration];

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(PKPushType)type {
  [RNVoipPushNotificationManager didUpdatePushCredentials:credentials forType:(NSString *)type];
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
             forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion {
  NSDictionary *p = payload.dictionaryPayload;
  NSString *uuid = p[@"call_id"] ?: [[NSUUID UUID] UUIDString];
  NSString *name = p[@"caller_name"] ?: @"";
  NSString *handle = p[@"caller_handle"] ?: name;
  BOOL hasVideo = [p[@"is_video"] isEqualToString:@"true"];

  [RNVoipPushNotificationManager didReceiveIncomingPushWithPayload:payload forType:(NSString *)type];

  // Báo CallKit ngay; RNCallKeep gọi completion sau khi báo xong.
  [RNCallKeep reportNewIncomingCall:uuid handle:handle handleType:@"generic" hasVideo:hasVideo
                localizedCallerName:name supportsHolding:NO supportsDTMF:NO supportsGrouping:NO
                 supportsUngrouping:NO fromPushKit:YES payload:p withCompletionHandler:completion];
}
```

Với `AppDelegate.swift` (React Native 0.77+), làm tương tự:

- Thêm `PKPushRegistryDelegate` vào khai báo class.
- Gọi `RNVoipPushNotificationManager.voipRegistration()` trong `didFinishLaunching`.
- Gọi `RNCallKeep.reportNewIncomingCall(...)` với các tham số như trên.
- Thêm các header Objective-C vào bridging header.

## 6. Cấu hình Android

Thêm vào `android/app/src/main/AndroidManifest.xml`, theo [hướng dẫn của react-native-callkeep](https://github.com/react-native-webrtc/react-native-callkeep/blob/master/docs/android-installation.md):

```xml
<uses-permission android:name="android.permission.BIND_TELECOM_CONNECTION_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.READ_PHONE_STATE" />
<uses-permission android:name="android.permission.CALL_PHONE" />

<application>
  <service android:name="io.wazo.callkeep.VoiceConnectionService"
      android:label="Wazo"
      android:permission="android.permission.BIND_TELECOM_CONNECTION_SERVICE"
      android:foregroundServiceType="camera|microphone"
      android:exported="true">
    <intent-filter><action android:name="android.telecom.ConnectionService" /></intent-filter>
  </service>
  <service android:name="io.wazo.callkeep.RNCallKeepBackgroundMessagingService" />
</application>
```

Lần đầu khởi tạo, Android hỏi quyền "tài khoản gọi điện". Có thể đổi chữ trên hộp thoại bằng `androidPermissionTexts`. Một số máy yêu cầu người dùng bật tài khoản gọi điện của app trong *Cài đặt → Ứng dụng gọi điện*.

## Kiểm tra nhanh

1. Chạy trên **máy thật**. Simulator iOS không nhận được VoIP push.
2. Bật `logging` và xem log `[TingPush] Đã đăng ký thiết bị …`.
3. Trên TingPush:
   - tab *Thiết bị*: máy iOS phải có badge **VoIP**;
   - tab *Gửi thông báo*, chọn **📞 Cuộc gọi**, gửi thử khi app đang mở, khi đã tắt và khi máy khoá.
