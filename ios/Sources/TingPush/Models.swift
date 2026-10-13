import Foundation

/// Thông tin cuộc gọi đọc từ payload push (giống nhau trên iOS và Android).
public struct TingPushCall {
    /// call_id do server gửi (UUID dạng chuỗi).
    public let id: String
    /// UUID dùng với CallKit.
    public let uuid: UUID
    public let callerName: String
    public let handle: String
    public let avatarUrl: String?
    public let isVideo: Bool
    /// Thời gian đổ chuông tối đa (giây).
    public let timeout: Int
    /// Toàn bộ payload, gồm cả các key "data" mà backend gửi kèm (vd room, token cuộc gọi…).
    public let data: [String: String]

    init?(payload: [AnyHashable: Any]) {
        var data: [String: String] = [:]
        for (key, value) in payload {
            guard let key = key as? String, key != "aps" else { continue }
            data[key] = value as? String ?? "\(value)"
        }
        guard let id = data["call_id"], let uuid = UUID(uuidString: id) else { return nil }
        self.id = id
        self.uuid = uuid
        self.callerName = data["caller_name"] ?? ""
        self.handle = data["caller_handle"] ?? ""
        self.avatarUrl = data["caller_avatar"]
        self.isVideo = data["is_video"] == "true"
        self.timeout = Int(data["timeout"] ?? "") ?? 45
        self.data = data
    }
}

/// Thông báo nhận được / người dùng bấm vào.
public struct TingPushNotification {
    public let title: String?
    public let body: String?
    /// Các key "data" backend gửi kèm (vd screen, id…).
    public let data: [String: String]
    /// Payload gốc của APNs (gồm "aps").
    public let rawPayload: [AnyHashable: Any]

    init(userInfo: [AnyHashable: Any], title: String? = nil, body: String? = nil) {
        var data: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, key != "aps", !key.hasPrefix("gcm.") else { continue }
            data[key] = value as? String ?? "\(value)"
        }
        let alert = (userInfo["aps"] as? [String: Any])?["alert"]
        let alertDict = alert as? [String: Any]
        // UNNotificationContent trả "" khi không có tiêu đề/nội dung.
        self.title = title.flatMap { $0.isEmpty ? nil : $0 } ?? alertDict?["title"] as? String
        self.body = body.flatMap { $0.isEmpty ? nil : $0 } ?? alertDict?["body"] as? String ?? alert as? String
        self.data = data
        self.rawPayload = userInfo
    }
}

/// Cấu hình màn hình cuộc gọi CallKit.
public struct TingPushCallConfiguration {
    /// Tên app hiển thị trên màn hình cuộc gọi (iOS 13). iOS 14+ tự lấy tên app.
    public var localizedName: String
    /// Ảnh PNG đơn sắc (template) 40x40pt hiển thị trên màn hình cuộc gọi.
    public var iconTemplateImageData: Data?
    /// Tên file âm thanh trong bundle app (vd "ringtone.caf"); nil = nhạc chuông hệ thống.
    public var ringtoneSound: String?
    public var supportsVideo: Bool
    /// Hiện cuộc gọi trong tab Gần đây của app Điện thoại.
    public var includesCallsInRecents: Bool

    public init(localizedName: String,
                iconTemplateImageData: Data? = nil,
                ringtoneSound: String? = nil,
                supportsVideo: Bool = true,
                includesCallsInRecents: Bool = true) {
        self.localizedName = localizedName
        self.iconTemplateImageData = iconTemplateImageData
        self.ringtoneSound = ringtoneSound
        self.supportsVideo = supportsVideo
        self.includesCallsInRecents = includesCallsInRecents
    }
}

/// Nhận sự kiện từ SDK. Mọi hàm đều có sẵn bản mặc định rỗng, chỉ cần cài hàm cần dùng. Luôn được gọi trên main thread.
public protocol TingPushDelegate: AnyObject {
    /// Đăng ký thiết bị với server thành công.
    func tingPush(didRegisterDevice deviceId: String)
    /// Người dùng bấm vào thông báo, kể cả khi app đang tắt. Bấm trước khi gán `delegate` thì sự kiện
    /// được giữ lại và gửi ngay khi gán.
    func tingPush(didOpenNotification notification: TingPushNotification)
    /// Nhận thông báo khi app đang mở, hoặc silent push.
    func tingPush(didReceiveNotification notification: TingPushNotification)
    /// Màn hình cuộc gọi đã hiện (đang đổ chuông).
    func tingPush(didReceiveIncomingCall call: TingPushCall)
    /// Người dùng bấm nghe: kết nối cuộc gọi (WebRTC/SIP…) tại đây.
    func tingPush(didAcceptCall call: TingPushCall)
    /// Người dùng từ chối khi đang đổ chuông.
    func tingPush(didDeclineCall call: TingPushCall)
    /// Cuộc gọi kết thúc sau khi đã nghe (người dùng cúp máy hoặc gọi TingPush.endCall).
    func tingPush(didEndCall call: TingPushCall)
    /// Hết thời gian đổ chuông mà không nghe, hoặc server báo call_ended trước khi nghe.
    func tingPush(didMissCall call: TingPushCall)
    /// CallKit đã bật audio session: bắt đầu phát/thu âm thanh cuộc gọi tại đây.
    func tingPushDidActivateAudioSession()
    func tingPush(didFailWithError error: Error)
}

public extension TingPushDelegate {
    func tingPush(didRegisterDevice deviceId: String) {}
    func tingPush(didOpenNotification notification: TingPushNotification) {}
    func tingPush(didReceiveNotification notification: TingPushNotification) {}
    func tingPush(didReceiveIncomingCall call: TingPushCall) {}
    func tingPush(didAcceptCall call: TingPushCall) {}
    func tingPush(didDeclineCall call: TingPushCall) {}
    func tingPush(didEndCall call: TingPushCall) {}
    func tingPush(didMissCall call: TingPushCall) {}
    func tingPushDidActivateAudioSession() {}
    func tingPush(didFailWithError error: Error) {}
}

public enum TingPushError: LocalizedError {
    case notInitialized
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized: return "TingPush chưa được initialize."
        case let .http(status, body): return "TingPush API lỗi \(status): \(body)"
        }
    }
}
