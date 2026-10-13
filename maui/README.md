# TingPush SDK cho .NET MAUI (C#)

Yêu cầu .NET 10 và MAUI 10 (target `net10.0-android` và `net10.0-ios`).

SDK viết hoàn toàn bằng C#:

- **Android:** dùng `Xamarin.Firebase.Messaging`. Màn hình cuộc gọi toàn màn hình và nhạc chuông lặp được dựng sẵn.
- **iOS:** dùng PushKit + CallKit gọi trực tiếp, **không cần Firebase**.

## 1. Cài đặt

Cài từ [NuGet](https://www.nuget.org/packages/TingPush.Maui):

```bash
dotnet add package TingPush.Maui
```

```xml
<!-- MyApp.csproj -->
<ItemGroup>
  <PackageReference Include="TingPush.Maui" Version="1.1.1" />
</ItemGroup>
```

Gói NuGet yêu cầu .NET 10 / MAUI 10. App dùng .NET 9 thì tham chiếu thẳng source (`ProjectReference` tới `maui/TingPush.Maui/TingPush.Maui.csproj` của repo này), sửa `TargetFrameworks` thành `net9.0-android;net9.0-ios` và hạ phiên bản `Microsoft.Maui.Controls` cho khớp.

## 2. Khởi tạo (`MauiProgram.cs`)

```csharp
using TingPushSdk;

public static MauiApp CreateMauiApp()
{
    var builder = MauiApp.CreateBuilder();
    builder
        .UseMauiApp<App>()
        .UseTingPush(new TingPushOptions
        {
            AppId = "APP_ID_CUA_BAN",
            AndroidNotificationIcon = "ic_notification",   // drawable trắng trong suốt; bỏ trống = icon app
            IosCallIconFile = "call_icon.png",             // ảnh template trên màn hình CallKit (tuỳ chọn)
            TextAnswer = "Nghe",
            TextDecline = "Từ chối",
#if DEBUG
            Logging = true,
#endif
        });
    return builder.Build();
}
```

`ServerUrl` mặc định là `https://tingpush.com`. Chỉ truyền khi tự host server TingPush hoặc test với server khác (vd server dev trong mạng LAN).

## 3. Nhận sự kiện (`App.xaml.cs`)

Mọi event đều chạy trên main thread.

```csharp
public partial class App : Application
{
    public App()
    {
        InitializeComponent();
        // using TingPushSdk;

        TingPush.CallEvent += (_, e) =>
        {
            switch (e.Action)
            {
                case TingPushCallAction.Accepted:
                    // Người dùng bấm Nghe → kết nối cuộc gọi thật (WebRTC/SIP/Agora…)
                    // bằng e.Call.Id và e.Call.Data["room"].
                    break;
                case TingPushCallAction.Declined:
                    // Báo server huỷ phía người gọi.
                    break;
                case TingPushCallAction.Ended:
                case TingPushCallAction.Missed:
                case TingPushCallAction.Incoming:
                    break;
            }
        };
        // Người dùng bấm thông báo (app đang mở, chạy nền hay đã tắt). Bấm trước khi gắn thì vẫn nhận được.
        TingPush.NotificationOpened += (_, e) =>
        {
            /* điều hướng theo e.Data["screen"]; có thêm e.Title, e.Body */
        };
        // Thông báo tới khi app đang mở.
        TingPush.NotificationReceived += (_, e) => { /* e.Title, e.Body, e.Data */ };
        TingPush.Error += (_, ex) => System.Diagnostics.Debug.WriteLine(ex);
    }

    protected override void OnStart()
    {
        // Android: người dùng bấm Nghe lúc app đang tắt → app mở ra sau đó.
        if (TingPush.TakeAcceptedCall() is { } call)
        {
            /* kết nối cuộc gọi */
        }
    }
}
```

Thêm `using TingPushSdk;` ở đầu các file dùng SDK. Mọi hàm đều là static trên class `TingPush`.

## 4. Gắn user và tag

```csharp
await TingPush.LoginAsync("user-123");          // sau khi đăng nhập
await TingPush.LogoutAsync();                   // khi đăng xuất
await TingPush.SetTagsAsync(new Dictionary<string, string> { ["plan"] = "vip" });
await TingPush.UnsubscribeAsync();              // SubscribeAsync() để nhận lại
var deviceId = TingPush.DeviceId;               // ID thiết bị trên TingPush
TingPush.EndCall(callId);                       // tắt cuộc gọi từ app (đầu bên kia cúp máy)
```

## 5. Cấu hình Android

1. **Firebase:**
   - Tạo app Android trên [Firebase Console](https://console.firebase.google.com). Package name phải trùng `ApplicationId` của app.
   - Tải `google-services.json` về, đặt vào `Platforms/Android/`, rồi khai báo trong `.csproj` của app:

     ```xml
     <ItemGroup Condition="$([MSBuild]::GetTargetPlatformIdentifier('$(TargetFramework)')) == 'android'">
       <GoogleServicesJson Include="Platforms\Android\google-services.json" />
     </ItemGroup>
     ```

   - Trên TingPush, upload service account JSON của **cùng project Firebase**.
2. **Activity chính:** `MainActivity` phải có `LaunchMode = LaunchMode.SingleTop` (template MAUI mặc định đã có). SDK tự xử lý intent khi người dùng bấm thông báo hoặc bấm Nghe.
3. **Manifest:** SDK tự khai báo quyền, service FCM và màn hình cuộc gọi. Không cần sửa `AndroidManifest.xml`.
4. **Để cuộc gọi đổ chuông ổn định** (Xiaomi, Oppo, Vivo, Android 14+): nên có màn hình cài đặt trong app.

   ```csharp
   #if ANDROID
   if (!TingPush.CanUseFullScreenIntent()) TingPush.OpenFullScreenIntentSettings();        // Android 14+
   if (!TingPush.IsIgnoringBatteryOptimizations()) TingPush.OpenBatteryOptimizationSettings();
   #endif
   ```

**App đã có `FirebaseMessagingService` riêng:** Android chỉ cho một service nhận FCM. Cho service của bạn kế thừa `TingPushSdk.TingPushMessagingService`, gọi `base.OnMessageReceived(message)` và `base.OnNewToken(token)`, rồi bỏ attribute `[Service]` trùng.

## 6. Cấu hình iOS

1. **AppDelegate.** Trong `Platforms/iOS/AppDelegate.cs`, đổi lớp cha để SDK nhận APNs token và push:

   ```csharp
   [Register("AppDelegate")]
   public class AppDelegate : TingPushSdk.TingPushAppDelegate   // thay cho MauiUIApplicationDelegate
   {
       protected override MauiApp CreateMauiApp() => MauiProgram.CreateMauiApp();
   }
   ```

2. **`Platforms/iOS/Info.plist`:**

   ```xml
   <key>UIBackgroundModes</key>
   <array>
     <string>remote-notification</string>
     <string>voip</string>
   </array>
   <key>NSMicrophoneUsageDescription</key>
   <string>Dùng micro cho cuộc gọi</string>
   ```

3. **`Platforms/iOS/Entitlements.plist`**, rồi trỏ `<CodesignEntitlements>Platforms/iOS/Entitlements.plist</CodesignEntitlements>` trong `.csproj`:

   ```xml
   <key>aps-environment</key>
   <string>development</string>   <!-- bản phát hành: production -->
   ```

4. **Apple Developer:** bật **Push Notifications** cho App ID. Trên TingPush, upload key `.p8`, Team ID, Key ID và Bundle ID.

**Môi trường APNs** được tự nhận diện từ provisioning profile: build debug là sandbox; TestFlight và App Store là production. Muốn chỉ định cố định thì đặt `IosSandbox = true/false`.

**Trên iOS, khi bấm Nghe:** SDK tự cấu hình `AVAudioSession` sang chế độ gọi. Thư viện WebRTC/SIP nên bắt đầu phát âm thanh sau sự kiện `Accepted`.

## Kiểm tra nhanh

1. Chạy trên **máy thật**. Simulator iOS không nhận được VoIP push; emulator Android phải có Google Play.
2. Bật `Logging = true` và xem Output: `[TingPush] Đã đăng ký thiết bị …`.
3. Trên TingPush:
   - tab *Thiết bị*: máy iOS phải có badge **VoIP**;
   - tab *Gửi thông báo*, chọn **📞 Cuộc gọi**, gửi thử khi app đang mở, khi đã tắt và khi máy khoá.
