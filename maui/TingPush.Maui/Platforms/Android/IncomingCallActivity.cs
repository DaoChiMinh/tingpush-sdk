using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.Graphics;
using Android.Graphics.Drawables;
using Android.OS;
using Android.Views;
using Android.Widget;
using Button = Android.Widget.Button;
using Color = Android.Graphics.Color;
using View = Android.Views.View;

namespace TingPushSdk;

/// <summary>
/// Màn hình cuộc gọi đến toàn màn hình, hiện cả khi máy đang khoá (qua full-screen intent).
/// Cũng nhận hành động "Nghe" từ notification: mở app chính kèm thông tin cuộc gọi.
/// </summary>
[Activity(
    Name = "com.tingpush.maui.IncomingCallActivity",
    Exported = false,
    LaunchMode = LaunchMode.SingleInstance,
    ExcludeFromRecents = true,
    TaskAffinity = "com.tingpush.maui.call",
    Theme = "@android:style/Theme.DeviceDefault.NoActionBar")]
public class IncomingCallActivity : Activity
{
    internal const string ActionShow = "com.tingpush.maui.SHOW_CALL";
    internal const string ActionAccept = "com.tingpush.maui.ACCEPT_CALL";

    private static WeakReference<IncomingCallActivity>? current;
    private TingPushCall? call;

    internal static Intent CreateIntent(Context context, TingPushCall call, string action)
    {
        var intent = new Intent(context, typeof(IncomingCallActivity));
        intent.SetAction(action);
        intent.PutExtra(CallNotifier.ExtraCall, CallNotifier.ToBundle(call));
        intent.AddFlags(ActivityFlags.NewTask | ActivityFlags.NoUserAction);
        return intent;
    }

    /// <summary>Đóng màn hình cuộc gọi nếu đang hiện đúng cuộc gọi này.</summary>
    internal static void FinishCall(string callId)
    {
        if (current?.TryGetTarget(out var activity) == true)
            activity.RunOnUiThread(() =>
            {
                if (activity.call?.Id == callId)
                    activity.Finish();
            });
    }

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        ShowOverLockScreen();
        HandleCallIntent(Intent);
    }

    protected override void OnNewIntent(Intent? intent)
    {
        base.OnNewIntent(intent);
        Intent = intent;
        HandleCallIntent(intent);
    }

    protected override void OnDestroy()
    {
        if (current?.TryGetTarget(out var activity) == true && activity == this)
            current = null;
        base.OnDestroy();
    }

    private void HandleCallIntent(Intent? intent)
    {
        if (CallNotifier.FromBundle(intent?.GetBundleExtra(CallNotifier.ExtraCall)) is not { } c)
        {
            Finish();
            return;
        }
        call = c;
        if (intent?.Action == ActionAccept)
        {
            Accept(c);
            return;
        }
        current = new WeakReference<IncomingCallActivity>(this);
        SetContentView(BuildView(c));
    }

    private void Accept(TingPushCall c)
    {
        CallNotifier.Accepted(this, c);
        if (PackageManager?.GetLaunchIntentForPackage(PackageName!) is not { } launch)
        {
            Finish();
            return;
        }
        launch.AddFlags(ActivityFlags.NewTask | ActivityFlags.SingleTop | ActivityFlags.ClearTop);
        launch.PutExtra(TingPush.ExtraAccepted, true);
        launch.PutExtra(CallNotifier.ExtraCall, CallNotifier.ToBundle(c));

        void OpenApp()
        {
            StartActivity(launch);
            Finish();
        }

        // Màn hình khoá có mật khẩu: yêu cầu mở khoá, xong (hoặc người dùng bỏ qua) mới mở app.
        var keyguard = (KeyguardManager?)GetSystemService(KeyguardService);
        if (OperatingSystem.IsAndroidVersionAtLeast(26) && keyguard?.IsKeyguardLocked == true)
            keyguard.RequestDismissKeyguard(this, new DismissCallback(OpenApp));
        else
            OpenApp();
    }

    private void Decline(TingPushCall c)
    {
        CallNotifier.Declined(this, c);
        Finish();
    }

    private void ShowOverLockScreen()
    {
        if (OperatingSystem.IsAndroidVersionAtLeast(27))
        {
            SetShowWhenLocked(true);
            SetTurnScreenOn(true);
        }
        else
        {
#pragma warning disable CA1422
            Window?.AddFlags(WindowManagerFlags.ShowWhenLocked | WindowManagerFlags.TurnScreenOn);
#pragma warning restore CA1422
        }
        Window?.AddFlags(WindowManagerFlags.KeepScreenOn);
    }

    /// <summary>Giao diện dựng bằng code để SDK không cần file layout/resource.</summary>
    private LinearLayout BuildView(TingPushCall c)
    {
        var options = TingPush.Options;
        var dp = Resources!.DisplayMetrics!.Density;
        int Px(float value) => (int)(value * dp);
        var name = string.IsNullOrEmpty(c.CallerName) ? c.Handle : c.CallerName;

        TextView Text(string value, float size, float alpha = 1f, bool bold = false)
        {
            var view = new TextView(this) { Text = value, TextSize = size, Alpha = alpha, Gravity = GravityFlags.Center };
            view.SetTextColor(Color.White);
            if (bold) view.Typeface = Typeface.DefaultBold;
            return view;
        }

        Button RoundButton(string label, string color, Action onClick)
        {
            var background = new GradientDrawable();
            background.SetShape(ShapeType.Rectangle);
            background.SetCornerRadius(40 * dp);
            background.SetColor(Color.ParseColor(color));

            var button = new Button(this) { Text = label, Background = background };
            button.SetTextColor(Color.White);
            button.Click += (_, _) => onClick();
            var lp = new LinearLayout.LayoutParams(0, Px(64), 1f);
            lp.SetMargins(Px(12), 0, Px(12), 0);
            button.LayoutParameters = lp;
            return button;
        }

        var avatarBackground = new GradientDrawable();
        avatarBackground.SetShape(ShapeType.Oval);
        avatarBackground.SetColor(Color.ParseColor("#3A3A3C"));
        var avatar = Text(name.Length > 0 ? name[..1].ToUpperInvariant() : "?", 40f, bold: true);
        avatar.Background = avatarBackground;
        avatar.LayoutParameters = new LinearLayout.LayoutParams(Px(110), Px(110))
        {
            Gravity = GravityFlags.CenterHorizontal,
            BottomMargin = Px(20)
        };

        var buttons = new LinearLayout(this) { Orientation = Orientation.Horizontal };
        buttons.AddView(RoundButton(options.TextDecline, "#FF3B30", () => Decline(c)));
        buttons.AddView(RoundButton(options.TextAnswer, "#34C759", () => Accept(c)));

        var root = new LinearLayout(this) { Orientation = Orientation.Vertical };
        root.SetGravity(GravityFlags.CenterHorizontal);
        root.SetBackgroundColor(Color.ParseColor("#1C1C1E"));
        root.SetPadding(Px(24), Px(120), Px(24), Px(64));
        root.AddView(avatar);
        root.AddView(Text(name, 28f, bold: true));
        if (c.Handle.Length > 0 && c.Handle != name)
            root.AddView(Text(c.Handle, 16f, 0.7f));
        root.AddView(Text(c.IsVideo ? options.TextIncomingVideo : options.TextIncomingAudio, 16f, 0.7f));
        root.AddView(new View(this) { LayoutParameters = new LinearLayout.LayoutParams(1, 0, 1f) });
        root.AddView(buttons);
        return root;
    }

    private sealed class DismissCallback(Action onDone) : KeyguardManager.KeyguardDismissCallback
    {
        public override void OnDismissSucceeded() => onDone();
        public override void OnDismissCancelled() => onDone();
        public override void OnDismissError() => onDone();
    }
}
