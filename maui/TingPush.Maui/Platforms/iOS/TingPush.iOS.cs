using Foundation;
using UIKit;
using UserNotifications;

namespace TingPushSdk;

public static partial class TingPush
{
    private static NotificationDelegate? notificationDelegate;

    static partial void PlatformInitialize()
    {
        notificationDelegate = new NotificationDelegate();
        UNUserNotificationCenter.Current.Delegate = notificationDelegate;

        if (Options.EnableCalls)
            CallManager.Shared.Start(Options);

        if (Options.RequestPermissionOnStart)
            RequestPermission();
        else
            UIApplication.SharedApplication.RegisterForRemoteNotifications();
    }

    static partial void PlatformEndCall(string callId) => CallManager.Shared.EndCall(callId);

    /// <summary>Xin quyền hiển thị thông báo rồi đăng ký APNs.</summary>
    public static void RequestPermission(Action<bool>? completion = null)
    {
        UNUserNotificationCenter.Current.RequestAuthorization(
            UNAuthorizationOptions.Alert | UNAuthorizationOptions.Sound | UNAuthorizationOptions.Badge,
            (granted, _) => MainThread.BeginInvokeOnMainThread(() =>
            {
                UIApplication.SharedApplication.RegisterForRemoteNotifications();
                completion?.Invoke(granted);
            }));
    }

    internal static void OnRegisteredForRemoteNotifications(NSData deviceToken) =>
        SetPushToken(Convert.ToHexString(deviceToken.ToArray()).ToLowerInvariant());

    /// <summary>Silent push / call_ended. Trả về true nếu SDK đã xử lý.</summary>
    internal static bool HandleRemoteNotification(NSDictionary userInfo)
    {
        var data = ToDictionary(userInfo);
        if (data.TryGetValue("type", out var type) && type == "call_ended" && data.TryGetValue("call_id", out var callId))
        {
            CallManager.Shared.RemoteEnded(callId);
            return true;
        }
        // Thông báo có alert khi app đang mở đã báo qua WillPresentNotification; ở đây chỉ báo silent push để không trùng.
        if ((userInfo.ObjectForKey(new NSString("aps")) as NSDictionary)?.ObjectForKey(new NSString("alert")) is null)
            RaiseNotificationReceived(data, null, null);
        return false;
    }

    internal static Dictionary<string, string> ToDictionary(NSDictionary dictionary)
    {
        var data = new Dictionary<string, string>();
        foreach (var (key, value) in dictionary)
        {
            if (key?.ToString() is { } k && k != "aps" && !k.StartsWith("gcm.") && value is not null)
                data[k] = value.ToString();
        }
        return data;
    }

    /// <summary>Bản build có embedded.mobileprovision với aps-environment = development là sandbox. App Store → production.</summary>
    private static partial bool IsSandbox()
    {
        if (Options.IosSandbox is { } sandbox)
            return sandbox;

        var path = NSBundle.MainBundle.PathForResource("embedded", "mobileprovision");
        if (path is null || !File.Exists(path))
            return false;
        var text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(path));
        var key = text.IndexOf("<key>aps-environment</key>", StringComparison.Ordinal);
        if (key < 0)
            return false;
        var start = text.IndexOf("<string>", key, StringComparison.Ordinal);
        var end = start < 0 ? -1 : text.IndexOf("</string>", start, StringComparison.Ordinal);
        return start >= 0 && end > start && text[(start + "<string>".Length)..end] == "development";
    }

    /// <summary>MAUI trả về mã máy (vd iPhone15,2) trên iOS.</summary>
    private static partial string DeviceModelIdentifier() => DeviceInfo.Model;

    private static string? NullIfEmpty(string? value) => string.IsNullOrEmpty(value) ? null : value;

    private sealed class NotificationDelegate : UNUserNotificationCenterDelegate
    {
        /// <summary>Thông báo đến khi app đang mở: vẫn hiện banner.</summary>
        public override void WillPresentNotification(UNUserNotificationCenter center, UNNotification notification,
            Action<UNNotificationPresentationOptions> completionHandler)
        {
            var content = notification.Request.Content;
            var data = ToDictionary(content.UserInfo);
            if (data.TryGetValue("type", out var type) && type == "call_ended" && data.TryGetValue("call_id", out var callId))
                CallManager.Shared.RemoteEnded(callId);
            else
                RaiseNotificationReceived(data, NullIfEmpty(content.Title), NullIfEmpty(content.Body));

            completionHandler(Options.ShowNotificationsInForeground
                ? UNNotificationPresentationOptions.Banner | UNNotificationPresentationOptions.List |
                  UNNotificationPresentationOptions.Sound | UNNotificationPresentationOptions.Badge
                : UNNotificationPresentationOptions.None);
        }

        /// <summary>Người dùng bấm vào thông báo.</summary>
        public override void DidReceiveNotificationResponse(UNUserNotificationCenter center, UNNotificationResponse response,
            Action completionHandler)
        {
            var content = response.Notification.Request.Content;
            RaiseNotificationOpened(ToDictionary(content.UserInfo), NullIfEmpty(content.Title), NullIfEmpty(content.Body));
            completionHandler();
        }
    }
}
