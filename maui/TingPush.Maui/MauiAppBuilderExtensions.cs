using Microsoft.Maui.LifecycleEvents;

namespace TingPushSdk;

public static class MauiAppBuilderExtensions
{
    /// <summary>
    /// Bật TingPush: đăng ký thiết bị, nhận thông báo và cuộc gọi. Gọi trong <c>MauiProgram.CreateMauiApp</c>.
    /// </summary>
    public static MauiAppBuilder UseTingPush(this MauiAppBuilder builder, TingPushOptions options)
    {
#if ANDROID
        // CreateMauiApp chạy trong MauiApplication.OnCreate, kể cả khi FCM đánh thức app đang tắt (không có Activity).
        TingPush.Initialize(options);
#endif
        builder.ConfigureLifecycleEvents(events =>
        {
#if ANDROID
            events.AddAndroid(android => android
                .OnCreate((activity, _) =>
                {
                    TingPush.HandleIntent(activity.Intent);
                    if (options.RequestPermissionOnStart)
                        TingPush.RequestNotificationPermission(activity);
                })
                .OnNewIntent((_, intent) => TingPush.HandleIntent(intent)));
#elif IOS
            // APNs token và push được chuyển tiếp qua TingPushAppDelegate (MAUI chưa có lifecycle event cho push).
            events.AddiOS(ios => ios.FinishedLaunching((_, _) =>
            {
                // Phải chạy ngay lúc khởi động: app được VoIP push đánh thức cần PushKit sẵn sàng.
                TingPush.Initialize(options);
                return true;
            }));
#endif
        });
        return builder;
    }
}
