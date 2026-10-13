using AVFoundation;
using CallKit;
using CoreFoundation;
using Foundation;
using PushKit;
using UIKit;

namespace TingPushSdk;

/// <summary>
/// Nhận VoIP push (PushKit) và hiển thị cuộc gọi bằng CallKit.
/// Quy tắc của Apple (iOS 13+): mỗi VoIP push PHẢI được báo thành cuộc gọi mới bằng ReportNewIncomingCall trước khi
/// gọi completion, nếu không app bị tắt và iOS ngừng giao VoIP push. Vì vậy cả payload lỗi cũng được báo rồi kết thúc ngay.
/// </summary>
internal sealed class CallManager
{
    public static CallManager Shared { get; } = new();

    private CXProvider? provider;
    private PKPushRegistry? registry;
    private readonly CXCallController callController = new();
    private readonly Dictionary<Guid, TingPushCall> calls = [];
    private readonly HashSet<Guid> answered = [];
    /// <summary>call_ended tới trước VoIP push (mạng chậm): không đổ chuông nữa.</summary>
    private readonly HashSet<string> endedBeforeShown = [];

    public void Start(TingPushOptions options)
    {
        var config = new CXProviderConfiguration
        {
            SupportsVideo = true,
            MaximumCallGroups = 1,
            MaximumCallsPerCallGroup = 1,
            IncludesCallsInRecents = true,
            SupportedHandleTypes = new NSSet<NSNumber>(NSNumber.FromNInt((nint)(long)CXHandleType.Generic),
                NSNumber.FromNInt((nint)(long)CXHandleType.PhoneNumber))
        };
        if (options.IosCallIconFile is { } icon && UIImage.FromBundle(icon) is { } image)
            config.IconTemplateImageData = image.AsPNG();

        provider = new CXProvider(config);
        provider.SetDelegate(new ProviderDelegate(this), DispatchQueue.MainQueue);

        registry = new PKPushRegistry(DispatchQueue.MainQueue)
        {
            Delegate = new VoipDelegate(this),
            DesiredPushTypes = new NSSet(new NSObject[] { PKPushType.Voip })
        };
    }

    public void EndCall(string callId)
    {
        if (!Guid.TryParse(callId, out var uuid) || !calls.ContainsKey(uuid))
            return;
        var transaction = new CXTransaction(new CXEndCallAction(new NSUuid(uuid.ToString())));
        callController.RequestTransaction(transaction, error =>
        {
            if (error is null)
                return;
            // Không kết thúc qua transaction được: báo trực tiếp cho CallKit.
            MainThread.BeginInvokeOnMainThread(() =>
            {
                provider?.ReportCall(new NSUuid(uuid.ToString()), NSDate.Now, CXCallEndedReason.RemoteEnded);
                Finish(uuid, missed: !answered.Contains(uuid));
            });
        });
    }

    /// <summary>Server gửi call_ended: người gọi huỷ, máy khác đã nghe, hoặc hết giờ.</summary>
    public void RemoteEnded(string callId) => MainThread.BeginInvokeOnMainThread(() =>
    {
        if (!Guid.TryParse(callId, out var uuid) || !calls.ContainsKey(uuid))
        {
            endedBeforeShown.Add(callId.ToLowerInvariant());
            return;
        }
        provider?.ReportCall(new NSUuid(uuid.ToString()), NSDate.Now, CXCallEndedReason.RemoteEnded);
        Finish(uuid, missed: !answered.Contains(uuid));
    });

    private void Finish(Guid uuid, bool missed)
    {
        if (!calls.Remove(uuid, out var call))
            return;
        var wasAnswered = answered.Remove(uuid);
        TingPush.RaiseCall(
            wasAnswered ? TingPushCallAction.Ended : missed ? TingPushCallAction.Missed : TingPushCallAction.Declined,
            call);
    }

    private void OnIncomingPush(PKPushPayload payload, Action completion)
    {
        if (provider is null)
        {
            completion();
            return;
        }

        var call = TingPushCall.FromData(TingPush.ToDictionary(payload.DictionaryPayload));
        var uuid = call is not null && Guid.TryParse(call.Id, out var id) ? id : Guid.NewGuid();
        var nsUuid = new NSUuid(uuid.ToString());
        var update = new CXCallUpdate
        {
            RemoteHandle = new CXHandle(CXHandleType.Generic,
                call is null ? "" : call.Handle.Length > 0 ? call.Handle : call.CallerName),
            LocalizedCallerName = call?.CallerName,
            HasVideo = call?.IsVideo ?? false,
            SupportsHolding = false,
            SupportsGrouping = false,
            SupportsUngrouping = false,
            SupportsDtmf = false
        };

        provider.ReportNewIncomingCall(nsUuid, update, error =>
        {
            try
            {
                if (call is null || error is not null)
                {
                    // Payload không hợp lệ (hoặc CallKit từ chối, vd đang Không làm phiền): vẫn phải báo rồi kết thúc.
                    if (error is null)
                        provider.ReportCall(nsUuid, NSDate.Now, CXCallEndedReason.Failed);
                    TingPush.Log($"VoIP push không hiển thị được: {error?.LocalizedDescription}");
                    return;
                }
                if (endedBeforeShown.Remove(call.Id.ToLowerInvariant()))
                {
                    provider.ReportCall(nsUuid, NSDate.Now, CXCallEndedReason.RemoteEnded);
                    return;
                }

                calls[uuid] = call;
                TingPush.RaiseCall(TingPushCallAction.Incoming, call);

                // Hết thời gian đổ chuông mà chưa nghe → cuộc gọi nhỡ.
                DispatchQueue.MainQueue.DispatchAfter(
                    new DispatchTime(DispatchTime.Now, TimeSpan.FromSeconds(call.TimeoutSeconds)), () =>
                    {
                        if (!calls.ContainsKey(uuid) || answered.Contains(uuid))
                            return;
                        provider.ReportCall(nsUuid, NSDate.Now, CXCallEndedReason.Unanswered);
                        Finish(uuid, missed: true);
                    });
            }
            finally
            {
                completion();
            }
        });
    }

    private sealed class VoipDelegate(CallManager owner) : PKPushRegistryDelegate
    {
        public override void DidUpdatePushCredentials(PKPushRegistry registry, PKPushCredentials credentials, string type)
        {
            if (type == PKPushType.Voip)
                TingPush.SetVoipToken(Convert.ToHexString(credentials.Token.ToArray()).ToLowerInvariant());
        }

        public override void DidInvalidatePushToken(PKPushRegistry registry, string type)
        {
            if (type == PKPushType.Voip)
                TingPush.SetVoipToken("");
        }

        public override void DidReceiveIncomingPush(PKPushRegistry registry, PKPushPayload payload, string type, Action completion)
        {
            if (type == PKPushType.Voip)
                owner.OnIncomingPush(payload, completion);
            else
                completion();
        }
    }

    private sealed class ProviderDelegate(CallManager owner) : CXProviderDelegate
    {
        public override void DidReset(CXProvider provider)
        {
            foreach (var uuid in owner.calls.Keys.ToList())
                owner.Finish(uuid, missed: false);
        }

        public override void PerformAnswerCallAction(CXProvider provider, CXAnswerCallAction action)
        {
            var uuid = Guid.Parse(action.CallUuid.AsString());
            if (!owner.calls.TryGetValue(uuid, out var call))
            {
                action.Fail();
                return;
            }
            owner.answered.Add(uuid);
            // Cấu hình audio session trước khi CallKit kích hoạt; app có thể đổi lại khi xử lý sự kiện.
            AVAudioSession.SharedInstance().SetCategory(AVAudioSessionCategory.PlayAndRecord,
                call.IsVideo ? AVAudioSessionMode.VideoChat : AVAudioSessionMode.VoiceChat,
                AVAudioSessionCategoryOptions.AllowBluetooth, out _);
            TingPush.RaiseCall(TingPushCallAction.Accepted, call);
            action.Fulfill();
        }

        public override void PerformEndCallAction(CXProvider provider, CXEndCallAction action)
        {
            owner.Finish(Guid.Parse(action.CallUuid.AsString()), missed: false);
            action.Fulfill();
        }

        public override void PerformSetMutedCallAction(CXProvider provider, CXSetMutedCallAction action) => action.Fulfill();
    }
}
