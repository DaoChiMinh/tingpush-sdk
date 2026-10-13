import Flutter
import PushKit
import UIKit
import flutter_callkit_incoming

/// Nhận VoIP push (PushKit) và báo ngay cho CallKit qua flutter_callkit_incoming.
///
/// Đăng ký trong lúc app khởi động (GeneratedPluginRegistrant) nên vẫn nhận được cuộc gọi khi app đang tắt:
/// iOS bắt buộc báo CallKit ngay trong lúc nhận VoIP push, không chờ được tới khi Dart chạy.
public class TingPushPlugin: NSObject, FlutterPlugin, PKPushRegistryDelegate {
    /// Giữ một registry cho cả app (background isolate của firebase_messaging cũng đăng ký plugin lần nữa).
    private static var shared: TingPushPlugin?

    private let voipRegistry = PKPushRegistry(queue: .main)

    public static func register(with registrar: FlutterPluginRegistrar) {
        guard shared == nil else { return }
        let plugin = TingPushPlugin()
        plugin.voipRegistry.delegate = plugin
        plugin.voipRegistry.desiredPushTypes = [.voIP]
        shared = plugin
    }

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        // "" = token đã bị huỷ → Dart gửi lên để server xoá VoIP token.
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                             for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP, let callkit = SwiftFlutterCallkitIncomingPlugin.sharedInstance else { return completion() }
        let p = payload.dictionaryPayload
        let data = flutter_callkit_incoming.Data(
            id: (p["call_id"] as? String) ?? UUID().uuidString,
            nameCaller: (p["caller_name"] as? String) ?? "",
            handle: (p["caller_handle"] as? String) ?? "",
            type: (p["is_video"] as? String) == "true" ? 1 : 0)
        data.duration = (Int((p["timeout"] as? String) ?? "") ?? 45) * 1000
        data.avatar = (p["caller_avatar"] as? String) ?? ""
        var extra: [String: Any] = [:]
        for (key, value) in p {
            if let key = key as? String, key != "aps" { extra[key] = value }
        }
        data.extra = extra as NSDictionary
        callkit.showCallkitIncoming(data, fromPushKit: true) {
            completion()
        }
    }
}
