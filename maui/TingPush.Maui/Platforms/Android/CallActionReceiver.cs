using Android.Content;

namespace TingPushSdk;

/// <summary>Nút "Từ chối" trên notification cuộc gọi.</summary>
[BroadcastReceiver(Name = "com.tingpush.maui.CallActionReceiver", Exported = false)]
internal class CallActionReceiver : BroadcastReceiver
{
    public const string ActionDecline = "com.tingpush.maui.DECLINE";

    public override void OnReceive(Context? context, Intent? intent)
    {
        if (context is null || intent?.Action != ActionDecline)
            return;
        if (CallNotifier.FromBundle(intent.GetBundleExtra(CallNotifier.ExtraCall)) is { } call)
            CallNotifier.Declined(context, call);
    }
}
