using Foundation;
using UIKit;

namespace TingPushSdk;

/// <summary>
/// AppDelegate nền cho iOS: chuyển tiếp APNs token và push cho SDK.
/// Trong Platforms/iOS/AppDelegate.cs của app, đổi <c>MauiUIApplicationDelegate</c> thành <c>TingPushAppDelegate</c>.
/// </summary>
public abstract class TingPushAppDelegate : MauiUIApplicationDelegate
{
    [Export("application:didRegisterForRemoteNotificationsWithDeviceToken:")]
    public virtual void RegisteredForRemoteNotifications(UIApplication application, NSData deviceToken) =>
        TingPush.OnRegisteredForRemoteNotifications(deviceToken);

    [Export("application:didFailToRegisterForRemoteNotificationsWithError:")]
    public virtual void FailedToRegisterForRemoteNotifications(UIApplication application, NSError error) =>
        TingPush.RaiseError(new TingPushException($"Đăng ký APNs lỗi: {error.LocalizedDescription}"));

    /// <summary>Silent push và call_ended (tắt màn hình cuộc gọi).</summary>
    [Export("application:didReceiveRemoteNotification:fetchCompletionHandler:")]
    public virtual void DidReceiveRemoteNotification(UIApplication application, NSDictionary userInfo,
        Action<UIBackgroundFetchResult> completionHandler)
    {
        TingPush.HandleRemoteNotification(userInfo);
        completionHandler(UIBackgroundFetchResult.NewData);
    }
}
