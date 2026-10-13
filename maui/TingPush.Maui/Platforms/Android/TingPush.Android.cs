using Android;
using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.Gms.Tasks;
using Android.OS;
using Android.Provider;
using AndroidX.Core.App;
using AndroidX.Core.Content;
using Firebase.Messaging;

namespace TingPushSdk;

public static partial class TingPush
{
    internal const string ExtraOpened = "com.tingpush.maui.OPENED";
    internal const string ExtraTitle = "com.tingpush.maui.TITLE";
    internal const string ExtraBody = "com.tingpush.maui.BODY";
    internal const string ExtraAccepted = "com.tingpush.maui.ACCEPTED";

    internal static Context AppContext => Android.App.Application.Context;

    static partial void PlatformInitialize()
    {
        CallNotifier.CreateChannels(AppContext);
        // Binding .NET đánh dấu GetToken là obsolete nhầm; đây vẫn là API chuẩn của FCM để lấy token.
#pragma warning disable CS0618
        FirebaseMessaging.Instance.GetToken().AddOnSuccessListener(new TaskListener(result =>
        {
            if (result?.ToString() is { Length: > 0 } token)
                SetPushToken(token);
        }));
#pragma warning restore CS0618
    }

    static partial void PlatformEndCall(string callId) => CallNotifier.Dismiss(AppContext, callId);

    private static partial bool IsSandbox() => false;

    private static partial string DeviceModelIdentifier() => DeviceInfo.Model;

    /// <summary>
    /// Xử lý intent mở app: người dùng bấm Nghe (phát <see cref="CallEvent"/> Accepted) hoặc bấm thông báo
    /// (phát <see cref="NotificationOpened"/>). SDK tự gọi trong OnCreate/OnNewIntent của Activity.
    /// </summary>
    public static bool HandleIntent(Intent? intent)
    {
        if (intent?.Extras is not { } extras)
            return false;

        if (intent.GetBooleanExtra(ExtraAccepted, false))
        {
            intent.RemoveExtra(ExtraAccepted);
            if (CallNotifier.FromBundle(intent.GetBundleExtra(CallNotifier.ExtraCall)) is not { } call)
                return false;
            RaiseCall(TingPushCallAction.Accepted, call);
            return true;
        }

        // Thông báo do FCM tự hiện khi app ở nền có "google.message_id"; do SDK hiện thì có ExtraOpened.
        if (!intent.GetBooleanExtra(ExtraOpened, false) && !extras.ContainsKey("google.message_id"))
            return false;

        var data = new Dictionary<string, string>();
        foreach (var key in extras.KeySet() ?? [])
        {
            if (key.StartsWith("google.") || key.StartsWith("gcm.") || key.StartsWith("com.tingpush.maui.") ||
                key is "from" or "collapse_key")
                continue;
            if (extras.GetString(key) is { } value)
                data[key] = value;
        }
        // Thông báo FCM tự hiện (app ở nền) không chuyển tiêu đề/nội dung vào intent nên Title/Body = null.
        var title = extras.GetString(ExtraTitle);
        var body = extras.GetString(ExtraBody);
        intent.RemoveExtra(ExtraOpened);
        intent.RemoveExtra(ExtraTitle);
        intent.RemoveExtra(ExtraBody);
        intent.RemoveExtra("google.message_id");
        RaiseNotificationOpened(data, title, body);
        return true;
    }

    /// <summary>Android 13+: xin quyền hiển thị thông báo.</summary>
    public static void RequestNotificationPermission(Activity activity)
    {
        if (OperatingSystem.IsAndroidVersionAtLeast(33) &&
            ContextCompat.CheckSelfPermission(activity, Manifest.Permission.PostNotifications) != Permission.Granted)
        {
            ActivityCompat.RequestPermissions(activity, [Manifest.Permission.PostNotifications], 7301);
        }
    }

    /// <summary>Android 14+: app có được hiện màn hình cuộc gọi toàn màn hình khi máy khoá không.</summary>
    public static bool CanUseFullScreenIntent() =>
        !OperatingSystem.IsAndroidVersionAtLeast(34) ||
        ((NotificationManager)AppContext.GetSystemService(Context.NotificationService)!).CanUseFullScreenIntent();

    /// <summary>Mở trang cài đặt cho phép hiện toàn màn hình (Android 14+).</summary>
    public static void OpenFullScreenIntentSettings()
    {
        if (!OperatingSystem.IsAndroidVersionAtLeast(34))
            return;
        var intent = new Intent(Settings.ActionManageAppUseFullScreenIntent, Android.Net.Uri.Parse($"package:{AppContext.PackageName}"));
        intent.AddFlags(ActivityFlags.NewTask);
        AppContext.StartActivity(intent);
    }

    /// <summary>App đã được miễn tối ưu pin chưa (giúp nhận cuộc gọi ổn định trên Xiaomi, Oppo, Vivo…).</summary>
    public static bool IsIgnoringBatteryOptimizations() =>
        ((PowerManager)AppContext.GetSystemService(Context.PowerService)!).IsIgnoringBatteryOptimizations(AppContext.PackageName);

    /// <summary>Mở trang cài đặt tối ưu pin của hệ thống để người dùng tắt cho app.</summary>
    public static void OpenBatteryOptimizationSettings()
    {
        var intent = new Intent(Settings.ActionIgnoreBatteryOptimizationSettings);
        intent.AddFlags(ActivityFlags.NewTask);
        AppContext.StartActivity(intent);
    }

    private sealed class TaskListener(Action<Java.Lang.Object?> onSuccess) : Java.Lang.Object, IOnSuccessListener
    {
        public void OnSuccess(Java.Lang.Object? result) => onSuccess(result);
    }
}
