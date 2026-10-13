using System.Diagnostics;
using System.Globalization;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TingPushSdk;

/// <summary>
/// Điểm vào của SDK. Khởi tạo bằng <c>builder.UseTingPush(...)</c> trong MauiProgram, rồi dùng các hàm static.
/// Các event luôn được gọi trên main thread.
/// </summary>
public static partial class TingPush
{
    private const string KeyDeviceId = "tingpush.deviceId";
    private const string KeyUserId = "tingpush.externalUserId";
    private const string KeyPushToken = "tingpush.pushToken";
    private const string KeyVoipToken = "tingpush.voipToken";
    private const string KeyPendingTags = "tingpush.pendingTags";
    private const string KeyUnsubscribed = "tingpush.unsubscribed";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private static readonly SemaphoreSlim SyncLock = new(1, 1);

    /// <summary>Cuộc gọi người dùng đã bấm nghe trước khi app gắn event (app được mở từ trạng thái tắt).</summary>
    private static TingPushCall? pendingAccepted;

    internal static TingPushOptions Options { get; private set; } = null!;

    /// <summary>Đăng ký thiết bị với server thành công (giá trị là device id).</summary>
    public static event EventHandler<string>? DeviceRegistered;

    /// <summary>Thông báo / data message nhận được khi app đang mở (không gồm push cuộc gọi).</summary>
    public static event EventHandler<TingPushNotificationEventArgs>? NotificationReceived;

    /// <summary>
    /// Người dùng bấm vào thông báo, kể cả khi app đang tắt. Bấm trước khi gắn event thì sự kiện được giữ lại
    /// và gửi ngay khi gắn handler đầu tiên.
    /// </summary>
    public static event EventHandler<TingPushNotificationEventArgs>? NotificationOpened
    {
        add
        {
            List<TingPushNotificationEventArgs> pending;
            lock (OpenedLock)
            {
                notificationOpened += value;
                pending = [.. pendingOpened];
                pendingOpened.Clear();
            }
            foreach (var e in pending)
                OnMain(() => notificationOpened?.Invoke(null, e));
        }
        remove
        {
            lock (OpenedLock)
                notificationOpened -= value;
        }
    }

    private static EventHandler<TingPushNotificationEventArgs>? notificationOpened;
    private static readonly List<TingPushNotificationEventArgs> pendingOpened = [];
    private static readonly Lock OpenedLock = new();

    /// <summary>Sự kiện cuộc gọi: đổ chuông, nghe, từ chối, kết thúc, nhỡ.</summary>
    public static event EventHandler<TingPushCallEventArgs>? CallEvent;

    public static event EventHandler<Exception>? Error;

    /// <summary>ID thiết bị trên TingPush (có sau khi đăng ký thành công).</summary>
    public static string? DeviceId => Preferences.Default.Get<string?>(KeyDeviceId, null);

    public static string? ExternalUserId => Preferences.Default.Get<string?>(KeyUserId, null);

    internal static void Initialize(TingPushOptions options)
    {
        Options = options;
        PlatformInitialize();
    }

    /// <summary>Gắn thiết bị với user trong hệ thống của bạn (gọi sau khi đăng nhập). Backend gửi theo External ID này.</summary>
    public static Task LoginAsync(string externalUserId)
    {
        Preferences.Default.Set(KeyUserId, externalUserId);
        return SyncAsync();
    }

    /// <summary>Bỏ gắn user (gọi khi đăng xuất).</summary>
    public static Task LogoutAsync()
    {
        Preferences.Default.Remove(KeyUserId);
        return SyncAsync();
    }

    /// <summary>Thay toàn bộ tag của thiết bị (dùng để lọc khi gửi). Dictionary rỗng = xoá hết tag.</summary>
    public static Task SetTagsAsync(IDictionary<string, string> tags)
    {
        Preferences.Default.Set(KeyPendingTags, JsonSerializer.Serialize(tags));
        return SyncAsync();
    }

    /// <summary>Ngừng nhận thông báo trên thiết bị này cho tới khi gọi <see cref="SubscribeAsync"/>.</summary>
    public static async Task UnsubscribeAsync()
    {
        Preferences.Default.Set(KeyUnsubscribed, true);
        if (DeviceId is not { } id)
            return;
        using var response = await Http.DeleteAsync(Url($"api/v1/apps/{Options.AppId}/devices/{id}"));
        if (!response.IsSuccessStatusCode)
            throw new TingPushException($"Huỷ đăng ký lỗi {(int)response.StatusCode}");
    }

    public static Task SubscribeAsync()
    {
        Preferences.Default.Set(KeyUnsubscribed, false);
        return SyncAsync();
    }

    /// <summary>Kết thúc / tắt màn hình cuộc gọi (đầu bên kia cúp máy qua kênh signaling của bạn, hoặc app tự cúp).</summary>
    public static void EndCall(string callId) => PlatformEndCall(callId);

    /// <summary>
    /// Cuộc gọi đã được bấm nghe trước khi app gắn event <see cref="CallEvent"/> (Android: app được mở từ trạng thái tắt
    /// bằng nút Nghe). Gọi một lần sau khi gắn event, vd trong OnStart của App.
    /// </summary>
    public static TingPushCall? TakeAcceptedCall()
    {
        var call = pendingAccepted;
        pendingAccepted = null;
        return call;
    }

    // ---------------- Nội bộ ----------------

    static partial void PlatformInitialize();

    static partial void PlatformEndCall(string callId);

    internal static void SetPushToken(string token)
    {
        Log($"Push token: {token}");
        Preferences.Default.Set(KeyPushToken, token);
        _ = SyncAsync();
    }

    /// <summary>iOS: VoIP token (PushKit). "" = token đã bị huỷ → server xoá.</summary>
    internal static void SetVoipToken(string token)
    {
        Log($"VoIP token: {(token.Length == 0 ? "(đã huỷ)" : token)}");
        if (Preferences.Default.Get<string?>(KeyVoipToken, null) == token)
            return;
        Preferences.Default.Set(KeyVoipToken, token);
        _ = SyncAsync();
    }

    /// <summary>Đăng ký (upsert) thiết bị. Chạy tuần tự; gọi lặp lại an toàn.</summary>
    internal static async Task SyncAsync()
    {
        await SyncLock.WaitAsync();
        try
        {
            await DoSyncAsync();
        }
        catch (Exception ex)
        {
            Log($"Đăng ký thiết bị lỗi: {ex.Message}");
            RaiseError(ex);
        }
        finally
        {
            SyncLock.Release();
        }
    }

    private static async Task DoSyncAsync()
    {
        if (Options is null || Preferences.Default.Get(KeyUnsubscribed, false))
            return;
        if (Preferences.Default.Get<string?>(KeyPushToken, null) is not { Length: > 0 } token)
            return; // chờ token

        var tags = Preferences.Default.Get<string?>(KeyPendingTags, null);
        var body = new JsonObject
        {
            ["platform"] = DeviceInfo.Platform == DevicePlatform.iOS ? "Ios" : "Android",
            ["token"] = token,
            ["isSandbox"] = DeviceInfo.Platform == DevicePlatform.iOS && IsSandbox(),
            // Server ghi đè externalUserId mỗi lần đăng ký nên luôn gửi giá trị hiện tại.
            ["externalUserId"] = ExternalUserId,
            ["appVersion"] = AppInfo.VersionString,
            ["language"] = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName,
            ["deviceModel"] = DeviceInfo.Platform == DevicePlatform.iOS ? DeviceModelIdentifier() : $"{DeviceInfo.Manufacturer} {DeviceInfo.Model}",
            ["deviceOs"] = DeviceInfo.VersionString
        };
        if (tags is not null)
            body["tags"] = JsonNode.Parse(tags);
        if (DeviceInfo.Platform == DevicePlatform.iOS && Preferences.Default.Get<string?>(KeyVoipToken, null) is { } voip)
            body["voipToken"] = voip;

        using var response = await Http.PostAsync(Url($"api/v1/apps/{Options.AppId}/devices"),
            new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json"));
        var text = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new TingPushException($"TingPush API lỗi {(int)response.StatusCode}: {text}");

        var id = JsonNode.Parse(text)?["id"]?.GetValue<string>() ?? throw new TingPushException($"Phản hồi không hợp lệ: {text}");
        Preferences.Default.Set(KeyDeviceId, id);
        // Tag đổi trong lúc đang gửi thì giữ lại để lần sync sau gửi tiếp.
        if (tags is not null && Preferences.Default.Get<string?>(KeyPendingTags, null) == tags)
            Preferences.Default.Remove(KeyPendingTags);

        Log($"Đã đăng ký thiết bị {id}");
        OnMain(() => DeviceRegistered?.Invoke(null, id));
    }

    private static Uri Url(string path) => new($"{Options.ServerUrl.TrimEnd('/')}/{path}");

    private static partial bool IsSandbox();

    private static partial string DeviceModelIdentifier();

    internal static void RaiseCall(TingPushCallAction action, TingPushCall call)
    {
        if (action == TingPushCallAction.Accepted && CallEvent is null)
            pendingAccepted = call;
        OnMain(() => CallEvent?.Invoke(null, new TingPushCallEventArgs(action, call)));
    }

    internal static void RaiseNotificationReceived(IDictionary<string, string> data, string? title, string? body) =>
        OnMain(() => NotificationReceived?.Invoke(null, new TingPushNotificationEventArgs(new Dictionary<string, string>(data), title, body)));

    internal static void RaiseNotificationOpened(IDictionary<string, string> data, string? title, string? body)
    {
        var args = new TingPushNotificationEventArgs(new Dictionary<string, string>(data), title, body);
        lock (OpenedLock)
        {
            if (notificationOpened is null)
            {
                pendingOpened.Add(args);
                return;
            }
        }
        OnMain(() => notificationOpened?.Invoke(null, args));
    }

    internal static void RaiseError(Exception error) => OnMain(() => Error?.Invoke(null, error));

    private static void OnMain(Action action) => MainThread.BeginInvokeOnMainThread(action);

    internal static void Log(string message)
    {
        if (Options?.Logging == true)
            Debug.WriteLine($"[TingPush] {message}");
    }
}
