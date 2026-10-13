namespace TingPushSdk;

/// <summary>Thông tin cuộc gọi đọc từ payload push (giống nhau trên iOS và Android).</summary>
/// <param name="Id">call_id do server gửi (UUID).</param>
/// <param name="TimeoutSeconds">Thời gian đổ chuông tối đa (giây).</param>
/// <param name="Data">Toàn bộ payload, gồm cả các key "data" mà backend gửi kèm (vd room, token cuộc gọi…).</param>
public sealed record TingPushCall(
    string Id,
    string CallerName,
    string Handle,
    string? AvatarUrl,
    bool IsVideo,
    int TimeoutSeconds,
    IReadOnlyDictionary<string, string> Data)
{
    public const int DefaultTimeoutSeconds = 45;

    public static TingPushCall? FromData(IDictionary<string, string>? data)
    {
        if (data is null || !data.TryGetValue("call_id", out var id) || string.IsNullOrEmpty(id))
            return null;

        return new TingPushCall(
            id,
            data.TryGetValue("caller_name", out var name) ? name : "",
            data.TryGetValue("caller_handle", out var handle) ? handle : "",
            data.TryGetValue("caller_avatar", out var avatar) && avatar.Length > 0 ? avatar : null,
            data.TryGetValue("is_video", out var video) && video == "true",
            data.TryGetValue("timeout", out var timeout) && int.TryParse(timeout, out var t) ? t : DefaultTimeoutSeconds,
            new Dictionary<string, string>(data));
    }
}

public enum TingPushCallAction
{
    /// <summary>Màn hình cuộc gọi đã hiện (đang đổ chuông).</summary>
    Incoming,

    /// <summary>Người dùng bấm nghe: kết nối cuộc gọi (WebRTC/SIP…) tại đây.</summary>
    Accepted,

    /// <summary>Người dùng từ chối khi đang đổ chuông.</summary>
    Declined,

    /// <summary>Cuộc gọi kết thúc sau khi đã nghe (người dùng cúp máy, hoặc server báo call_ended).</summary>
    Ended,

    /// <summary>Hết thời gian đổ chuông, hoặc người gọi huỷ trước khi nghe.</summary>
    Missed
}

public sealed class TingPushCallEventArgs(TingPushCallAction action, TingPushCall call) : EventArgs
{
    public TingPushCallAction Action { get; } = action;

    public TingPushCall Call { get; } = call;
}

public sealed class TingPushNotificationEventArgs(IReadOnlyDictionary<string, string> data, string? title, string? body) : EventArgs
{
    public IReadOnlyDictionary<string, string> Data { get; } = data;

    public string? Title { get; } = title;

    public string? Body { get; } = body;
}

/// <summary>Cấu hình SDK, truyền vào <c>builder.UseTingPush(...)</c>.</summary>
public sealed class TingPushOptions
{
    /// <summary>App ID của dự án trên TingPush.</summary>
    public required string AppId { get; init; }

    /// <summary>Địa chỉ TingPush, vd https://push.example.com</summary>
    public required string ServerUrl { get; init; }

    /// <summary>Bật nhận cuộc gọi (iOS: PushKit + CallKit; Android: màn hình cuộc gọi).</summary>
    public bool EnableCalls { get; init; } = true;

    /// <summary>iOS: môi trường APNs. null = tự nhận diện từ provisioning profile (debug từ Xcode/VS = sandbox).</summary>
    public bool? IosSandbox { get; init; }

    /// <summary>Xin quyền thông báo ngay khi app khởi động.</summary>
    public bool RequestPermissionOnStart { get; init; } = true;

    /// <summary>Hiện thông báo khi app đang mở.</summary>
    public bool ShowNotificationsInForeground { get; init; } = true;

    /// <summary>Hiện thông báo "Cuộc gọi nhỡ" (Android) khi hết giờ đổ chuông hoặc người gọi huỷ.</summary>
    public bool ShowMissedCallNotification { get; init; } = true;

    /// <summary>iOS: tên file PNG template (trong Resources của app) làm icon trên màn hình CallKit.</summary>
    public string? IosCallIconFile { get; init; }

    /// <summary>Android: tên drawable làm icon nhỏ trên thanh trạng thái (vd "ic_notification"). null = icon app.</summary>
    public string? AndroidNotificationIcon { get; init; }

    public string TextIncomingAudio { get; init; } = "Cuộc gọi thoại đến";
    public string TextIncomingVideo { get; init; } = "Cuộc gọi video đến";
    public string TextAnswer { get; init; } = "Nghe";
    public string TextDecline { get; init; } = "Từ chối";
    public string TextMissedCall { get; init; } = "Cuộc gọi nhỡ";
    public string TextCallChannel { get; init; } = "Cuộc gọi đến";
    public string TextNotificationChannel { get; init; } = "Thông báo";

    public bool Logging { get; init; }
}

public sealed class TingPushException(string message) : Exception(message);
