using System.Collections.Concurrent;
using Android.App;
using Android.Content;
using Android.Media;
using Android.OS;
using AndroidX.Core.App;
using Person = AndroidX.Core.App.Person;

namespace TingPushSdk;

/// <summary>
/// Hiển thị cuộc gọi đến: notification CallStyle + full-screen intent (màn hình cuộc gọi khi máy khoá),
/// nhạc chuông lặp (FLAG_INSISTENT) cho tới khi nghe / từ chối / hết giờ.
/// </summary>
internal static class CallNotifier
{
    internal const string ExtraCall = "com.tingpush.maui.CALL";
    private const string ChannelCall = "tingpush_incoming_call";
    private const string ChannelMissed = "tingpush_missed_call";
    private const string ChannelDefault = "tingpush_default";

    private static readonly Handler MainHandler = new(Looper.MainLooper!);

    /// <summary>Cuộc gọi đang đổ chuông, theo call id.</summary>
    private static readonly ConcurrentDictionary<string, TingPushCall> Ringing = new();

    /// <summary>Cuộc gọi đã nghe (để báo Ended khi server gửi call_ended).</summary>
    private static readonly ConcurrentDictionary<string, TingPushCall> Answered = new();

    /// <summary>call_ended tới trước incoming_call (mạng chậm): không đổ chuông nữa.</summary>
    private static readonly ConcurrentDictionary<string, byte> EndedBeforeShown = new();

    private static TingPushOptions Options => TingPush.Options;

    public static void CreateChannels(Context context)
    {
        if (!OperatingSystem.IsAndroidVersionAtLeast(26))
            return;
        var manager = (NotificationManager)context.GetSystemService(Context.NotificationService)!;

        var callChannel = new NotificationChannel(ChannelCall, Options.TextCallChannel, NotificationImportance.High)
        {
            LockscreenVisibility = NotificationVisibility.Public
        };
        callChannel.SetSound(RingtoneManager.GetDefaultUri(RingtoneType.Ringtone),
            new AudioAttributes.Builder()
                .SetUsage(AudioUsageKind.NotificationRingtone)!
                .SetContentType(AudioContentType.Sonification)!
                .Build());
        callChannel.EnableVibration(true);
        callChannel.SetVibrationPattern([0, 1000, 1000]);
        manager.CreateNotificationChannel(callChannel);
        manager.CreateNotificationChannel(new NotificationChannel(ChannelMissed, Options.TextMissedCall, NotificationImportance.Default));
        manager.CreateNotificationChannel(new NotificationChannel(ChannelDefault, Options.TextNotificationChannel, NotificationImportance.High));
    }

    public static void ShowIncoming(Context context, TingPushCall call)
    {
        if (EndedBeforeShown.TryRemove(call.Id, out _))
            return;
        if (!Ringing.TryAdd(call.Id, call))
            return; // push trùng

        var id = NotificationId(call.Id);
        var person = new Person.Builder()
            .SetName(string.IsNullOrEmpty(call.CallerName) ? (string.IsNullOrEmpty(call.Handle) ? "?" : call.Handle) : call.CallerName)!
            .SetImportant(true)!
            .Build();

        var flags = PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable;
        var fullScreen = PendingIntent.GetActivity(context, id,
            IncomingCallActivity.CreateIntent(context, call, IncomingCallActivity.ActionShow), flags)!;
        var answer = PendingIntent.GetActivity(context, id + 1,
            IncomingCallActivity.CreateIntent(context, call, IncomingCallActivity.ActionAccept), flags)!;
        var declineIntent = new Intent(context, typeof(CallActionReceiver))
            .SetAction(CallActionReceiver.ActionDecline)!
            .PutExtra(ExtraCall, ToBundle(call));
        var decline = PendingIntent.GetBroadcast(context, id + 2, declineIntent, flags)!;

        var builder = new NotificationCompat.Builder(context, ChannelCall)
            .SetSmallIcon(SmallIcon(context))!
            .SetContentTitle(string.IsNullOrEmpty(call.CallerName) ? call.Handle : call.CallerName)!
            .SetContentText(call.IsVideo ? Options.TextIncomingVideo : Options.TextIncomingAudio)!
            .SetCategory(NotificationCompat.CategoryCall)!
            .SetPriority(NotificationCompat.PriorityMax)!
            .SetVisibility(NotificationCompat.VisibilityPublic)!
            .SetOngoing(true)!
            .SetAutoCancel(false)!
            .SetContentIntent(fullScreen)!
            .SetFullScreenIntent(fullScreen, true)!
            .SetTimeoutAfter(call.TimeoutSeconds * 1000L)!
            .SetStyle(NotificationCompat.CallStyle.ForIncomingCall(person, decline, answer)!.SetIsVideo(call.IsVideo))!
            .SetSound(RingtoneManager.GetDefaultUri(RingtoneType.Ringtone))! // Android < 8
            .SetVibrate([0, 1000, 1000])!;

        var notification = builder.Build()!;
        notification.Flags |= NotificationFlags.Insistent; // lặp chuông tới khi huỷ
        Notify(context, id, notification);
        TingPush.RaiseCall(TingPushCallAction.Incoming, call);

        MainHandler.PostDelayed(() =>
        {
            if (Ringing.ContainsKey(call.Id))
                Missed(context, call, null, null);
        }, call.TimeoutSeconds * 1000L);
    }

    /// <summary>Người dùng bấm Nghe.</summary>
    public static void Accepted(Context context, TingPushCall call)
    {
        if (!Ringing.TryRemove(call.Id, out _))
            return;
        Answered[call.Id] = call;
        Cancel(context, call.Id);
    }

    /// <summary>Người dùng bấm Từ chối.</summary>
    public static void Declined(Context context, TingPushCall call)
    {
        if (!Ringing.TryRemove(call.Id, out _))
            return;
        Cancel(context, call.Id);
        TingPush.RaiseCall(TingPushCallAction.Declined, call);
    }

    /// <summary>Server gửi call_ended: người gọi huỷ, máy khác đã nghe, hoặc đầu bên kia cúp máy.</summary>
    public static void RemoteEnded(Context context, string callId, string? title, string? body)
    {
        if (Ringing.TryGetValue(callId, out var call))
            Missed(context, call, title, body);
        else if (Answered.TryRemove(callId, out var answered))
            TingPush.RaiseCall(TingPushCallAction.Ended, answered);
        else
            EndedBeforeShown[callId] = 0;
    }

    /// <summary>App tự tắt cuộc gọi (TingPush.EndCall).</summary>
    public static void Dismiss(Context context, string callId)
    {
        Ringing.TryRemove(callId, out _);
        Answered.TryRemove(callId, out _);
        Cancel(context, callId);
    }

    private static void Missed(Context context, TingPushCall call, string? title, string? body)
    {
        if (!Ringing.TryRemove(call.Id, out _))
            return;
        Cancel(context, call.Id);
        TingPush.RaiseCall(TingPushCallAction.Missed, call);

        if (!Options.ShowMissedCallNotification)
            return;
        var id = NotificationId(call.Id) + 3;
        var missedTitle = title ?? Options.TextMissedCall;
        var missedBody = body ?? (string.IsNullOrEmpty(call.CallerName) ? call.Handle : call.CallerName);
        var notification = new NotificationCompat.Builder(context, ChannelMissed)
            .SetSmallIcon(SmallIcon(context))!
            .SetContentTitle(missedTitle)!
            .SetContentText(missedBody)!
            .SetCategory(NotificationCompat.CategoryMissedCall)!
            .SetAutoCancel(true)!
            .SetContentIntent(OpenAppIntent(context, missedTitle, missedBody, call.Data, id))!
            .Build()!;
        Notify(context, id, notification);
    }

    /// <summary>Thông báo thường khi app đang mở.</summary>
    public static void ShowNotification(Context context, string? title, string? body, IDictionary<string, string> data)
    {
        var id = (int)(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() & 0x7fffffff);
        var notification = new NotificationCompat.Builder(context, ChannelDefault)
            .SetSmallIcon(SmallIcon(context))!
            .SetContentTitle(title)!
            .SetContentText(body)!
            .SetStyle(new NotificationCompat.BigTextStyle().BigText(body))!
            .SetPriority(NotificationCompat.PriorityHigh)!
            .SetAutoCancel(true)!
            .SetContentIntent(OpenAppIntent(context, title, body, data, id))!
            .Build()!;
        Notify(context, id, notification);
    }

    internal static Bundle ToBundle(TingPushCall call)
    {
        var bundle = new Bundle();
        foreach (var (key, value) in call.Data)
            bundle.PutString(key, value);
        return bundle;
    }

    internal static TingPushCall? FromBundle(Bundle? bundle)
    {
        if (bundle is null)
            return null;
        var data = new Dictionary<string, string>();
        foreach (var key in bundle.KeySet() ?? [])
        {
            if (bundle.GetString(key) is { } value)
                data[key] = value;
        }
        return TingPushCall.FromData(data);
    }

    private static void Cancel(Context context, string callId)
    {
        NotificationManagerCompat.From(context)!.Cancel(NotificationId(callId));
        IncomingCallActivity.FinishCall(callId);
    }

    private static PendingIntent? OpenAppIntent(Context context, string? title, string? body,
        IEnumerable<KeyValuePair<string, string>> data, int requestCode)
    {
        if (context.PackageManager?.GetLaunchIntentForPackage(context.PackageName!) is not { } launch)
            return null;
        launch.AddFlags(ActivityFlags.SingleTop | ActivityFlags.ClearTop);
        foreach (var (key, value) in data)
            launch.PutExtra(key, value);
        launch.PutExtra(TingPush.ExtraOpened, true);
        if (title is not null)
            launch.PutExtra(TingPush.ExtraTitle, title);
        if (body is not null)
            launch.PutExtra(TingPush.ExtraBody, body);
        return PendingIntent.GetActivity(context, requestCode, launch, PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);
    }

    private static void Notify(Context context, int id, Notification notification)
    {
        try
        {
            NotificationManagerCompat.From(context)!.Notify(id, notification);
        }
        catch (Java.Lang.SecurityException ex)
        {
            // Chưa được cấp quyền POST_NOTIFICATIONS (Android 13+).
            TingPush.Log($"Không hiện được thông báo: {ex.Message}");
            TingPush.RaiseError(ex);
        }
    }

    private static int SmallIcon(Context context)
    {
        if (Options.AndroidNotificationIcon is { } name)
        {
            var id = context.Resources!.GetIdentifier(name, "drawable", context.PackageName);
            if (id != 0)
                return id;
        }
        return context.ApplicationInfo!.Icon;
    }

    /// <summary>Mỗi cuộc gọi dùng 4 id liền nhau: thông báo, nghe, từ chối, cuộc gọi nhỡ.</summary>
    private static int NotificationId(string callId) => (StableHash(callId) & 0x0fffffff) * 4;

    /// <summary>string.GetHashCode đổi theo mỗi lần chạy app; cần id ổn định giữa các process.</summary>
    private static int StableHash(string value)
    {
        unchecked
        {
            var hash = 17;
            foreach (var c in value)
                hash = hash * 31 + c;
            return hash;
        }
    }
}
