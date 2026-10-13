import AVFoundation
import CallKit
import Foundation
import PushKit

/// Nhận VoIP push (PushKit) và hiển thị cuộc gọi bằng CallKit.
///
/// Quy tắc của Apple (iOS 13+): mỗi VoIP push PHẢI được báo thành một cuộc gọi mới bằng
/// `reportNewIncomingCall` trước khi completion được gọi, nếu không app bị tắt và iOS ngừng giao VoIP push.
/// Vì vậy cả payload lỗi cũng được báo rồi kết thúc ngay.
final class CallManager: NSObject {
    static let shared = CallManager()

    private var provider: CXProvider?
    private let callController = CXCallController()
    private var registry: PKPushRegistry?

    private var calls: [UUID: TingPushCall] = [:]
    private var answered: Set<UUID> = []
    /// Cuộc gọi server đã báo kết thúc trước khi VoIP push tới (mạng chậm): không đổ chuông nữa.
    private var endedBeforeShown: Set<String> = []

    func start(configuration: TingPushCallConfiguration) {
        let config: CXProviderConfiguration
        if #available(iOS 14.0, *) {
            config = CXProviderConfiguration()
        } else {
            config = CXProviderConfiguration(localizedName: configuration.localizedName)
        }
        config.supportsVideo = configuration.supportsVideo
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic, .phoneNumber]
        config.iconTemplateImageData = configuration.iconTemplateImageData
        config.ringtoneSound = configuration.ringtoneSound
        config.includesCallsInRecents = configuration.includesCallsInRecents

        let provider = CXProvider(configuration: config)
        provider.setDelegate(self, queue: .main)
        self.provider = provider

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func endCall(callId: String) {
        guard let uuid = UUID(uuidString: callId), calls[uuid] != nil else { return }
        let transaction = CXTransaction(action: CXEndCallAction(call: uuid))
        callController.request(transaction) { error in
            if let error = error {
                TingPush.shared.log("Kết thúc cuộc gọi lỗi: \(error)")
                // Không kết thúc qua transaction được (vd chưa nghe): báo trực tiếp cho CallKit.
                self.provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                self.finish(uuid, missed: !self.answered.contains(uuid))
            }
        }
    }

    /// Server gửi call_ended: người gọi huỷ, máy khác đã nghe, hoặc hết giờ.
    func remoteEnded(callId: String) {
        DispatchQueue.main.async {
            guard let uuid = UUID(uuidString: callId), self.calls[uuid] != nil else {
                self.endedBeforeShown.insert(callId)
                return
            }
            self.provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            self.finish(uuid, missed: !self.answered.contains(uuid))
        }
    }

    private func finish(_ uuid: UUID, missed: Bool) {
        guard let call = calls.removeValue(forKey: uuid) else { return }
        let wasAnswered = answered.remove(uuid) != nil
        let delegate = TingPush.shared.delegate
        if wasAnswered {
            delegate?.tingPush(didEndCall: call)
        } else if missed {
            delegate?.tingPush(didMissCall: call)
        } else {
            delegate?.tingPush(didDeclineCall: call)
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension CallManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        TingPush.shared.setVoipToken(pushCredentials.token.map { String(format: "%02x", $0) }.joined())
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        TingPush.shared.setVoipToken("")
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP, let provider = provider else {
            completion()
            return
        }

        let call = TingPushCall(payload: payload.dictionaryPayload)
        let uuid = call?.uuid ?? UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: call?.handle.isEmpty == false ? call!.handle : (call?.callerName ?? ""))
        update.localizedCallerName = call?.callerName
        update.hasVideo = call?.isVideo ?? false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            defer { completion() }
            guard let call = call, error == nil else {
                // Payload không hợp lệ (hoặc CallKit từ chối, vd đang Không làm phiền): vẫn phải báo rồi kết thúc.
                if error == nil { provider.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
                TingPush.shared.log("VoIP push không hiển thị được: \(String(describing: error))")
                return
            }
            if self.endedBeforeShown.remove(call.id) != nil {
                provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                return
            }

            self.calls[uuid] = call
            TingPush.shared.delegate?.tingPush(didReceiveIncomingCall: call)

            // Hết thời gian đổ chuông mà chưa nghe → cuộc gọi nhỡ.
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(call.timeout)) {
                guard self.calls[uuid] != nil, !self.answered.contains(uuid) else { return }
                provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                self.finish(uuid, missed: true)
            }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        for uuid in Array(calls.keys) {
            finish(uuid, missed: false)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = calls[action.callUUID] else {
            action.fail()
            return
        }
        answered.insert(action.callUUID)
        // Cấu hình audio session trước khi CallKit kích hoạt; app có thể đổi lại trong delegate.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: call.isVideo ? .videoChat : .voiceChat,
                                                         options: [.allowBluetooth])
        TingPush.shared.delegate?.tingPush(didAcceptCall: call)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        finish(action.callUUID, missed: false)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        TingPush.shared.delegate?.tingPushDidActivateAudioSession()
    }
}
