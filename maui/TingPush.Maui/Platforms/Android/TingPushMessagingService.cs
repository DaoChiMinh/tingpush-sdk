using Android.App;
using Firebase.Messaging;

namespace TingPushSdk;

/// <summary>
/// Nhận push từ FCM. Được tự khai báo vào AndroidManifest của app khi build.
/// Nếu app có FirebaseMessagingService riêng, hãy kế thừa class này (gọi base) — xem README.
/// </summary>
[Service(Name = "com.tingpush.maui.TingPushMessagingService", Exported = false)]
[IntentFilter(["com.google.firebase.MESSAGING_EVENT"])]
public class TingPushMessagingService : FirebaseMessagingService
{
#pragma warning disable CS0672 // binding đánh dấu obsolete nhầm; FCM vẫn gọi OnNewToken khi token đổi.
    public override void OnNewToken(string token) => TingPush.SetPushToken(token);
#pragma warning restore CS0672

    public override void OnMessageReceived(RemoteMessage message)
    {
        var data = message.Data ?? new Dictionary<string, string>();
        data.TryGetValue("type", out var type);
        switch (type)
        {
            case "incoming_call":
                // Server đặt TTL = thời gian đổ chuông nên FCM không giao cuộc gọi đã quá hạn.
                if (TingPush.Options?.EnableCalls != false && TingPushCall.FromData(data) is { } call)
                    CallNotifier.ShowIncoming(this, call);
                break;
            case "call_ended":
                if (data.TryGetValue("call_id", out var callId))
                {
                    data.TryGetValue("title", out var title);
                    data.TryGetValue("body", out var body);
                    CallNotifier.RemoteEnded(this, callId, title, body);
                }
                break;
            default:
                var notification = message.GetNotification();
                // Có khối notification: app ở nền thì FCM tự hiện; tới đây nghĩa là app đang mở.
                if (notification is not null && TingPush.Options?.ShowNotificationsInForeground != false)
                    CallNotifier.ShowNotification(this, notification.Title, notification.Body, data);
                TingPush.RaiseNotificationReceived(data, notification?.Title, notification?.Body);
                break;
        }
    }
}
