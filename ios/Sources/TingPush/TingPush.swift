import Foundation
import UIKit
import UserNotifications

/// Điểm vào của SDK. Dùng qua `TingPush.shared`.
///
/// ```swift
/// TingPush.shared.initialize(appId: "…", callConfiguration: .init(localizedName: "MyApp"))
/// ```
public final class TingPush: NSObject {
    public static let shared = TingPush()

    /// Địa chỉ server TingPush mặc định.
    public static let defaultServerURL = URL(string: "https://tingpush.com")!

    public weak var delegate: TingPushDelegate? {
        didSet {
            guard delegate != nil, !pendingOpened.isEmpty else { return }
            let opened = pendingOpened
            pendingOpened.removeAll()
            DispatchQueue.main.async { opened.forEach { self.delegate?.tingPush(didOpenNotification: $0) } }
        }
    }

    /// Thông báo được bấm khi chưa có delegate (vd app SwiftUI gán delegate muộn).
    private var pendingOpened: [TingPushNotification] = []

    /// Bật log ra console để debug.
    public var loggingEnabled = false

    /// ID thiết bị trên TingPush (có sau khi đăng ký thành công).
    public var deviceId: String? { defaults.string(forKey: Keys.deviceId) }

    public var externalUserId: String? { defaults.string(forKey: Keys.externalUserId) }

    private enum Keys {
        static let deviceId = "tingpush.deviceId"
        static let externalUserId = "tingpush.externalUserId"
        static let apnsToken = "tingpush.apnsToken"
        static let voipToken = "tingpush.voipToken"
        static let pendingTags = "tingpush.pendingTags"
        static let unsubscribed = "tingpush.unsubscribed"
    }

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "tingpush.sdk")
    private var api: TingPushAPI?
    private var isSandbox = false
    private var syncing = false
    private var syncAgain = false
    /// VoIP token mới chưa gửi lên server (nil = không đổi).
    private var voipTokenToSend: String?

    private override init() {}

    // MARK: - Khởi tạo

    /// Gọi trong `application(_:didFinishLaunchingWithOptions:)`, trước khi return.
    /// - Parameters:
    ///   - appId: App ID của dự án trên TingPush.
    ///   - serverURL: địa chỉ server TingPush; chỉ cần đổi khi tự host server hoặc test với server khác.
    ///   - callConfiguration: truyền vào để bật nhận cuộc gọi (PushKit + CallKit). nil = không dùng cuộc gọi.
    ///   - isSandbox: môi trường APNs. nil = tự nhận diện từ provisioning profile (debug từ Xcode = sandbox).
    ///   - handleNotificationCenter: SDK làm delegate của UNUserNotificationCenter (hiện banner khi app đang mở,
    ///     báo sự kiện bấm thông báo). Đặt false nếu app đã có delegate riêng, khi đó tự gọi các hàm `handle…`.
    ///   - requestPermission: tự xin quyền thông báo ngay. Đặt false để tự gọi `requestPermission` lúc phù hợp.
    public func initialize(appId: String,
                           serverURL: URL = TingPush.defaultServerURL,
                           callConfiguration: TingPushCallConfiguration? = nil,
                           isSandbox: Bool? = nil,
                           handleNotificationCenter: Bool = true,
                           requestPermission: Bool = true) {
        api = TingPushAPI(serverURL: serverURL, appId: appId)
        self.isSandbox = isSandbox ?? TingPush.detectSandbox()

        if handleNotificationCenter {
            UNUserNotificationCenter.current().delegate = self
        }
        if let config = callConfiguration {
            CallManager.shared.start(configuration: config)
        }
        if requestPermission {
            self.requestPermission(completion: nil)
        } else {
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Xin quyền hiển thị thông báo rồi đăng ký APNs.
    public func requestPermission(completion: ((Bool) -> Void)?) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
                completion?(granted)
            }
        }
    }

    // MARK: - Chuyển tiếp từ AppDelegate

    /// Gọi trong `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        log("APNs token: \(token)")
        defaults.set(token, forKey: Keys.apnsToken)
        sync()
    }

    /// Gọi trong `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        log("Đăng ký APNs lỗi: \(error)")
        notifyError(error)
    }

    /// Gọi trong `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` (silent push, call_ended).
    /// Trả về true nếu SDK đã xử lý.
    @discardableResult
    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        if handleCallEnded(userInfo) { return true }
        // Thông báo có alert khi app đang mở đã báo qua willPresent; ở đây chỉ báo silent push để không trùng.
        if (userInfo["aps"] as? [String: Any])?["alert"] == nil {
            emitReceived(TingPushNotification(userInfo: userInfo))
        }
        return false
    }

    /// Gọi nếu app có UNUserNotificationCenterDelegate riêng (`handleNotificationCenter: false`), trong `didReceive response`.
    public func handleNotificationOpened(_ response: UNNotificationResponse) {
        let content = response.notification.request.content
        let notification = TingPushNotification(userInfo: content.userInfo, title: content.title, body: content.body)
        DispatchQueue.main.async {
            if let delegate = self.delegate {
                delegate.tingPush(didOpenNotification: notification)
            } else {
                self.pendingOpened.append(notification)
            }
        }
    }

    private func handleCallEnded(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["type"] as? String == "call_ended", let callId = userInfo["call_id"] as? String else { return false }
        CallManager.shared.remoteEnded(callId: callId)
        return true
    }

    private func emitReceived(_ notification: TingPushNotification) {
        DispatchQueue.main.async { self.delegate?.tingPush(didReceiveNotification: notification) }
    }

    // MARK: - Người dùng

    /// Gắn thiết bị với user trong hệ thống của bạn (gọi sau khi đăng nhập). Backend gửi theo External ID này.
    public func login(externalUserId: String) {
        defaults.set(externalUserId, forKey: Keys.externalUserId)
        sync()
    }

    /// Bỏ gắn user (gọi khi đăng xuất). Thiết bị vẫn nhận thông báo gửi tới tất cả.
    public func logout() {
        defaults.removeObject(forKey: Keys.externalUserId)
        sync()
    }

    /// Thay toàn bộ tag của thiết bị (dùng để lọc khi gửi). `[:]` = xoá hết tag.
    public func setTags(_ tags: [String: String]) {
        defaults.set(tags, forKey: Keys.pendingTags)
        sync()
    }

    /// Ngừng nhận thông báo trên thiết bị này cho tới khi gọi `subscribe()`.
    public func unsubscribe(completion: ((Error?) -> Void)? = nil) {
        defaults.set(true, forKey: Keys.unsubscribed)
        guard let api = api, let deviceId = deviceId else {
            completion?(nil)
            return
        }
        api.unsubscribe(deviceId: deviceId) { result in
            DispatchQueue.main.async {
                if case let .failure(error) = result { completion?(error) } else { completion?(nil) }
            }
        }
    }

    /// Nhận thông báo trở lại sau `unsubscribe()`.
    public func subscribe() {
        defaults.set(false, forKey: Keys.unsubscribed)
        sync()
    }

    // MARK: - Cuộc gọi

    /// Kết thúc cuộc gọi đang hiển thị trên CallKit (vd đầu bên kia cúp máy, hoặc app tự cúp).
    public func endCall(callId: String) {
        CallManager.shared.endCall(callId: callId)
    }

    // MARK: - Nội bộ

    func setVoipToken(_ token: String) {
        log("VoIP token: \(token.isEmpty ? "(đã huỷ)" : token)")
        queue.async {
            if self.defaults.string(forKey: Keys.voipToken) == token { return }
            self.defaults.set(token, forKey: Keys.voipToken)
            self.voipTokenToSend = token
            self.syncLocked()
        }
    }

    /// Đăng ký (upsert) thiết bị với server. Gọi lặp lại an toàn; các lần gọi chồng nhau được gộp lại.
    private func sync() {
        queue.async { self.syncLocked() }
    }

    private func syncLocked() {
        guard let api = api else { return }
        guard let token = defaults.string(forKey: Keys.apnsToken) else { return } // chờ APNs token
        if defaults.bool(forKey: Keys.unsubscribed) { return }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true

        var body: [String: Any] = [
            "platform": "Ios",
            "token": token,
            "isSandbox": isSandbox,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "language": Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "",
            "deviceModel": TingPush.deviceModel(),
            "deviceOs": UIDevice.current.systemVersion
        ]
        // Server ghi đè externalUserId mỗi lần đăng ký nên luôn gửi giá trị hiện tại (NSNull = không có user).
        if let userId = externalUserId { body["externalUserId"] = userId } else { body["externalUserId"] = NSNull() }
        let tags = defaults.dictionary(forKey: Keys.pendingTags) as? [String: String]
        if let tags = tags { body["tags"] = tags }
        let voip = voipTokenToSend ?? defaults.string(forKey: Keys.voipToken)
        if let voip = voip { body["voipToken"] = voip }

        api.register(body) { result in
            self.queue.async {
                self.syncing = false
                switch result {
                case let .success(deviceId):
                    self.defaults.set(deviceId, forKey: Keys.deviceId)
                    if tags != nil { self.defaults.removeObject(forKey: Keys.pendingTags) }
                    if self.voipTokenToSend == voip { self.voipTokenToSend = nil }
                    self.log("Đã đăng ký thiết bị \(deviceId)")
                    DispatchQueue.main.async { self.delegate?.tingPush(didRegisterDevice: deviceId) }
                case let .failure(error):
                    self.log("Đăng ký thiết bị lỗi: \(error.localizedDescription)")
                    self.notifyError(error)
                }
                if self.syncAgain {
                    self.syncAgain = false
                    self.syncLocked()
                }
            }
        }
    }

    func notifyError(_ error: Error) {
        DispatchQueue.main.async { self.delegate?.tingPush(didFailWithError: error) }
    }

    func log(_ message: String) {
        if loggingEnabled { print("[TingPush] \(message)") }
    }

    /// Bản build có embedded.mobileprovision với aps-environment = development là sandbox.
    /// App Store không có file này → production.
    private static func detectSandbox() -> Bool {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .isoLatin1),
              let keyRange = text.range(of: "<key>aps-environment</key>"),
              let start = text.range(of: "<string>", range: keyRange.upperBound..<text.endIndex),
              let end = text.range(of: "</string>", range: start.upperBound..<text.endIndex)
        else { return false }
        return text[start.upperBound..<end.lowerBound] == "development"
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension TingPush: UNUserNotificationCenterDelegate {
    /// Thông báo đến khi app đang mở: vẫn hiện banner. Nếu app có delegate riêng thì gọi hàm này từ đó.
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        if !handleCallEnded(content.userInfo) {
            emitReceived(TingPushNotification(userInfo: content.userInfo, title: content.title, body: content.body))
        }
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    /// Người dùng bấm vào thông báo.
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        handleNotificationOpened(response)
        completionHandler()
    }
}
