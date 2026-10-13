# TingPush SDK cho iOS (Swift)

Yêu cầu iOS 13+ và Xcode 14+. SDK không phụ thuộc thư viện nào khác; không cần Firebase.

## 1. Cài đặt

**Swift Package Manager**

Xcode → *File → Add Package Dependencies…* → nhập `https://github.com/DaoChiMinh/tingpush-sdk`, chọn *Up to Next Major Version* từ `1.0.0`.

Trong `Package.swift` của bạn:

```swift
.package(url: "https://github.com/DaoChiMinh/tingpush-sdk", from: "1.1.0")
// target: .product(name: "TingPush", package: "tingpush-sdk")
```

**CocoaPods** (chép thư mục `ios/` của repo này vào project):

```ruby
pod 'TingPush', :path => './TingPushSDK/ios'
```

## 2. Cấu hình project (Signing & Capabilities)

1. **Push Notifications**: bật.
2. **Background Modes**: tick **Remote notifications** và **Voice over IP**.
   - Voice over IP chỉ cần nếu dùng cuộc gọi.
   - Bật xong thì `Info.plist` có `UIBackgroundModes` gồm `remote-notification` và `voip`.
3. Nếu gọi có tiếng, thêm `NSMicrophoneUsageDescription` vào `Info.plist`. Gọi video thì thêm cả `NSCameraUsageDescription`.

## 3. Khởi tạo trong AppDelegate

```swift
import UIKit
import TingPush

@main
class AppDelegate: UIResponder, UIApplicationDelegate, TingPushDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        TingPush.shared.delegate = self
        TingPush.shared.loggingEnabled = true   // tắt khi phát hành
        TingPush.shared.initialize(
            appId: "APP_ID_CUA_BAN",
            // Bỏ tham số này nếu không dùng cuộc gọi.
            callConfiguration: TingPushCallConfiguration(
                localizedName: "MyApp",
                iconTemplateImageData: UIImage(named: "CallIcon")?.pngData()
            )
        )
        return true
    }

    // Chuyển tiếp 3 hàm sau cho SDK.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        TingPush.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        TingPush.shared.didFailToRegisterForRemoteNotifications(error: error)
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        TingPush.shared.handleRemoteNotification(userInfo)
        completionHandler(.newData)
    }
}
```

`serverURL` mặc định là `https://tingpush.com`. Chỉ truyền khi tự host server TingPush hoặc test với server khác (vd server dev trong mạng LAN).

**Lưu ý:**

- **Phải gọi `initialize` trong `didFinishLaunchingWithOptions`.** Khi có cuộc gọi đến lúc app đã tắt, iOS mở app chạy ngầm. Lúc đó SDK cần đăng ký PushKit ngay để nhận VoIP push.
- **Môi trường APNs (sandbox/production)** được tự nhận diện từ provisioning profile:
  - Build debug từ Xcode là sandbox.
  - TestFlight và App Store là production.
  - Muốn chỉ định cố định thì truyền `isSandbox:`.
- **App dùng SwiftUI** (`@main struct App`): thêm `@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate` và đặt code trên vào class `AppDelegate`.

## 4. Gắn user và tag

```swift
// Sau khi đăng nhập: backend gửi theo External ID này.
TingPush.shared.login(externalUserId: "user-123")

// Khi đăng xuất.
TingPush.shared.logout()

// Thay toàn bộ tag; [:] = xoá hết.
TingPush.shared.setTags(["plan": "vip", "city": "hn"])

// Ngừng nhận / nhận lại thông báo.
TingPush.shared.unsubscribe()
TingPush.shared.subscribe()

// ID thiết bị trên TingPush.
TingPush.shared.deviceId
```

## 5. Nhận sự kiện

Chỉ cần cài những hàm bạn dùng. Mọi hàm đều chạy trên main thread.

```swift
extension AppDelegate {
    // Người dùng bấm thông báo (app đang mở, chạy nền hay đã tắt) → điều hướng theo data.
    func tingPush(didOpenNotification notification: TingPushNotification) {
        // notification.data["screen"], notification.title, notification.body
    }

    // Thông báo tới khi app đang mở (SDK vẫn hiện banner), hoặc silent push.
    func tingPush(didReceiveNotification notification: TingPushNotification) { }

    func tingPush(didAcceptCall call: TingPushCall) {
        // Người dùng bấm Nghe → kết nối cuộc gọi thật (WebRTC/SIP…) bằng call.id và call.data["room"].
    }

    func tingPushDidActivateAudioSession() {
        // CallKit đã bật audio: bắt đầu phát/thu âm thanh (vd RTCAudioSession.isAudioEnabled = true).
    }

    func tingPush(didDeclineCall call: TingPushCall) {
        // Báo server để huỷ phía người gọi.
    }

    func tingPush(didEndCall call: TingPushCall) {
        // Người dùng cúp máy → đóng kết nối.
    }

    func tingPush(didMissCall call: TingPushCall) {
        // Hết giờ đổ chuông, hoặc người gọi huỷ.
    }

    func tingPush(didFailWithError error: Error) {
        print(error)
    }
}
```

**Kết thúc cuộc gọi từ app**, ví dụ khi đầu bên kia cúp máy qua kênh signaling của bạn:

```swift
TingPush.shared.endCall(callId: call.id)
```

## 6. App đã có UNUserNotificationCenter delegate riêng

Truyền `handleNotificationCenter: false` vào `initialize`, rồi gọi SDK từ delegate của bạn:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    TingPush.shared.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
}

func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                            withCompletionHandler completionHandler: @escaping () -> Void) {
    TingPush.shared.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
}
```

## Kiểm tra nhanh

1. Chạy app trên **máy thật**. Simulator không nhận được VoIP push.
2. Xem log `[TingPush] Đã đăng ký thiết bị …`.
3. Trên TingPush, tab *Thiết bị* phải thấy máy iOS có badge **VoIP**.
4. Tab *Gửi thông báo*, chọn **📞 Cuộc gọi**, gửi tới thiết bị đó. Thử khi app đang mở, khi app đã tắt và khi máy đang khoá.

## Câu hỏi thường gặp

- **APNs báo `BadDeviceToken`:** sai môi trường sandbox/production. Kiểm tra lại `isSandbox`.
- **App bị tắt ngay khi nhận cuộc gọi:** VoIP push nào cũng phải được báo cho CallKit. SDK đã làm việc này. Nếu app có code PushKit riêng, hãy xoá đi để tránh xung đột.
- **Không có badge VoIP trên TingPush:** chưa bật Background Mode *Voice over IP*, hoặc chưa truyền `callConfiguration`.
