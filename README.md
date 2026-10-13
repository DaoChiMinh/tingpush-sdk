# TingPush SDK

SDK để tích hợp app mobile với TingPush. SDK tự lo các việc sau:

- Đăng ký thiết bị với server và tự đăng ký lại khi token đổi.
- Gắn thiết bị với user của bạn (`login` / `logout`) và đặt tag.
- Hiện thông báo, kể cả khi app đang mở, và báo cho app khi người dùng bấm vào thông báo.
- **Cuộc gọi đến kiểu Zalo/Messenger:** hiện màn hình cuộc gọi, đổ chuông cả khi app đã tắt hoặc máy đang khoá, có nút nghe/từ chối, tự tắt khi hết giờ hoặc khi người gọi huỷ.

| Nền tảng | Thư mục | Hướng dẫn |
|---|---|---|
| iOS (Swift) | [`ios/`](ios) | [ios/README.md](ios/README.md) |
| Android (Kotlin/Java) | [`android/`](android) | [android/README.md](android/README.md) |
| Flutter (Dart) | [`flutter/tingpush/`](flutter/tingpush) | [flutter/tingpush/README.md](flutter/tingpush/README.md) |
| React Native (TypeScript) | [`react-native/tingpush/`](react-native/tingpush) | [react-native/tingpush/README.md](react-native/tingpush/README.md) |
| .NET MAUI (C#) | [`maui/TingPush.Maui/`](maui/TingPush.Maui) | [maui/README.md](maui/README.md) |

## Chuẩn bị trên TingPush

1. Tạo dự án và lấy **App ID**. App ID là thông tin công khai, nhúng vào app.
2. Vào *Cấu hình push*:
   - **iOS:** upload key `.p8`, nhập Team ID, Key ID và Bundle ID. Key này dùng được cho cả VoIP push.
   - **Android:** upload service account JSON của project Firebase mà app đang dùng.
3. **API Key** (`psk_…`) chỉ dùng ở **backend** để gửi thông báo. Không nhúng key này vào app.

## Luồng hoạt động

```
App mobile ── SDK ── POST /api/v1/apps/{appId}/devices ──► TingPush (lưu token, VoIP token, user, tag)
Backend ─────────── POST /notifications (API Key) ───────► TingPush ──► APNs / FCM ──► SDK trên máy
```

- **iOS:** server gửi thẳng tới APNs bằng APNs device token. Cuộc gọi đi qua **VoIP push (PushKit)** tới VoIP token, rồi app hiện bằng **CallKit**.
- **Android:** server gửi qua FCM. Cuộc gọi là **data message ưu tiên cao**; SDK tự hiện màn hình cuộc gọi.

## Payload cuộc gọi (giống nhau trên mọi SDK)

| Key | Ý nghĩa |
|---|---|
| `type` | `incoming_call` hoặc `call_ended` |
| `call_id` | UUID của cuộc gọi |
| `caller_name`, `caller_handle`, `caller_avatar` | Thông tin người gọi |
| `is_video` | `"true"` / `"false"` |
| `timeout` | Số giây đổ chuông |
| *(các key khác)* | Lấy từ `data` mà backend gửi kèm, ví dụ `room` hay token phòng gọi |

Mọi SDK đều báo các sự kiện **incoming**, **accepted**, **declined**, **ended** và **missed/timeout**, kèm thông tin cuộc gọi. Khi nhận **accepted**, app kết nối cuộc gọi thật (WebRTC, SIP, Agora, Stringee…) bằng `call_id` và `data`.

## Gửi từ backend

Endpoint: `POST {server}/notifications`, header `Authorization: Key psk_…`.

**Cuộc gọi đến:**

```json
{
  "app_id": "<App ID>",
  "include_aliases": { "external_id": ["user-2"] },
  "call": {
    "action": "incoming",
    "id": "6f1c2a3e-8a7b-4c5d-9e0f-1a2b3c4d5e6f",
    "caller_name": "Nguyễn Văn A",
    "handle": "0901234567",
    "is_video": false,
    "timeout": 45
  },
  "data": { "room": "abc" }
}
```

**Kết thúc cuộc gọi.** Gửi khi người gọi huỷ, khi một máy khác của cùng user đã nghe, hoặc khi hết giờ. Các máy còn đang đổ chuông sẽ tắt chuông.

```json
{
  "app_id": "<App ID>",
  "include_aliases": { "external_id": ["user-2"] },
  "headings": { "en": "Cuộc gọi nhỡ" },
  "contents": { "en": "Nguyễn Văn A đã gọi cho bạn" },
  "call": { "action": "ended", "id": "6f1c2a3e-8a7b-4c5d-9e0f-1a2b3c4d5e6f" }
}
```

`id` phải là **UUID**. Backend nên tự sinh `id` và lưu lại, để sau đó gửi được `ended` với cùng `id`.

**C# (.NET)**

```csharp
using var http = new HttpClient { BaseAddress = new Uri("https://push.example.com") };
http.DefaultRequestHeaders.Add("Authorization", "Key psk_xxx");
var callId = Guid.NewGuid();
var res = await http.PostAsJsonAsync("/notifications", new
{
    app_id = "<App ID>",
    include_aliases = new { external_id = new[] { "user-2" } },
    call = new { action = "incoming", id = callId, caller_name = "Nguyễn Văn A", is_video = false },
    data = new { room = "abc" }
});
```

**Node.js**

```js
const callId = crypto.randomUUID();
await fetch('https://push.example.com/notifications', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: 'Key psk_xxx' },
  body: JSON.stringify({
    app_id: '<App ID>',
    include_aliases: { external_id: ['user-2'] },
    call: { action: 'incoming', id: callId, caller_name: 'Nguyễn Văn A', is_video: false },
    data: { room: 'abc' },
  }),
});
```

**PHP**

```php
$ch = curl_init('https://push.example.com/notifications');
curl_setopt_array($ch, [
    CURLOPT_POST => true,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'Authorization: Key psk_xxx'],
    CURLOPT_POSTFIELDS => json_encode([
        'app_id' => '<App ID>',
        'include_aliases' => ['external_id' => ['user-2']],
        'headings' => ['en' => 'Đơn hàng đã giao'],
        'contents' => ['en' => 'Đơn #42 đã giao thành công'],
        'data' => ['screen' => 'order', 'id' => '42'],
    ]),
]);
$result = curl_exec($ch);
```

## Lưu ý chung để cuộc gọi đổ chuông ổn định

- **iOS:** gần như luôn đổ chuông, kể cả khi app đã tắt hoặc máy đang khoá. Gạt im lặng thì chỉ rung. Chế độ Tập trung chặn theo cài đặt của người dùng.
- **Android:** ổn định trên máy Pixel và Samsung. Trên Xiaomi, Oppo, Vivo, Realme và Huawei, nên hướng dẫn người dùng (giống Zalo):
  - bật **Tự khởi động**,
  - **tắt tối ưu pin** cho app,
  - với **Android 14+**, cấp quyền **hiển thị toàn màn hình**.

  Các SDK có sẵn hàm kiểm tra và mở các trang cài đặt này.
- **Máy Huawei không có Google Play Services:** không nhận được FCM.
- **Người dùng bấm "Buộc dừng" app:** app không nhận được push nào cho tới khi mở lại.
