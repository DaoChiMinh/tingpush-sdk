import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Handler nền SDK tự đăng ký với `FirebaseMessaging.onBackgroundMessage` trong [TingPush.initialize].
/// App có handler nền riêng thì gọi [TingPush.handleBackgroundMessage] trong handler đó.
@pragma('vm:entry-point')
Future<void> tingPushBackgroundHandler(RemoteMessage message) async {
  await TingPush.handleBackgroundMessage(message);
}

/// Điểm vào của SDK. Mọi hàm đều là static.
///
/// ```dart
/// await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
/// await TingPush.initialize(appId: '…', serverUrl: 'https://push.example.com');
/// TingPush.onNotificationOpened.listen((n) { /* điều hướng theo n.data */ });
/// ```
class TingPush {
  TingPush._();

  static const _kDeviceId = 'tingpush.deviceId';
  static const _kUserId = 'tingpush.externalUserId';
  static const _kPendingTags = 'tingpush.pendingTags';
  static const _kUnsubscribed = 'tingpush.unsubscribed';
  static const _kStyle = 'tingpush.callStyle';

  static const _channel = MethodChannel('tingpush');

  static String? _appId;
  static Uri? _serverUrl;
  static bool _iosSandbox = false;
  static bool _logging = false;
  static bool _showInForeground = true;
  static bool _launchEventsChecked = false;
  static TingPushCallStyle _style = const TingPushCallStyle();
  static String? _voipToken;
  static Future<void> _syncChain = Future.value();
  static final Map<String, TingPushCall> _calls = {};
  static final Set<String> _acceptedEmitted = {};
  static final List<StreamSubscription<Object?>> _subscriptions = [];

  static final _callEvents = _BufferedStream<TingPushCallEvent>();
  static final _received = StreamController<TingPushNotification>.broadcast();
  static final _opened = _BufferedStream<TingPushNotification>();
  static final _registered = StreamController<String>.broadcast();
  static final _errors = StreamController<Object>.broadcast();

  /// Sự kiện cuộc gọi: đổ chuông, nghe, từ chối, kết thúc, hết giờ. Gồm cả cuộc gọi đã bấm nghe lúc app còn tắt.
  /// Sự kiện xảy ra trước khi có ai nghe stream được giữ lại và gửi cho listener đầu tiên.
  static Stream<TingPushCallEvent> get onCallEvent => _callEvents.stream;

  /// Thông báo / data message nhận được khi app đang mở (không gồm push cuộc gọi).
  static Stream<TingPushNotification> get onNotificationReceived => _received.stream;

  /// Người dùng bấm vào thông báo, dù app đang mở, chạy nền hay đã tắt hẳn.
  /// Sự kiện xảy ra trước khi có ai nghe stream được giữ lại và gửi cho listener đầu tiên.
  static Stream<TingPushNotification> get onNotificationOpened => _opened.stream;

  /// Đăng ký thiết bị với server thành công (giá trị là device id).
  static Stream<String> get onDeviceRegistered => _registered.stream;

  static Stream<Object> get onError => _errors.stream;

  /// Cuộc gọi người dùng đã bấm nghe khi app còn tắt. Không cần gọi nếu đã nghe [onCallEvent].
  static Future<TingPushCall?> getAcceptedCall() async {
    final calls = await FlutterCallkitIncoming.activeCalls();
    for (final c in calls) {
      if (c.isAccepted) return _callFromParams(c);
    }
    return null;
  }

  /// ID thiết bị trên TingPush (có sau khi đăng ký thành công).
  static Future<String?> get deviceId async => (await SharedPreferences.getInstance()).getString(_kDeviceId);

  static Future<String?> get externalUserId async => (await SharedPreferences.getInstance()).getString(_kUserId);

  /// Gọi sau `Firebase.initializeApp`.
  ///
  /// - [appId]: App ID của dự án trên TingPush.
  /// - [serverUrl]: địa chỉ TingPush, vd `https://push.example.com`.
  /// - [iosSandbox]: môi trường APNs của token iOS. Mặc định: debug/profile = sandbox, release = production.
  ///   Bản TestFlight/App Store là production; build release cài từ Xcode bằng profile development thì truyền true.
  /// - [requestPermission]: xin quyền thông báo ngay (iOS, Android 13+).
  /// - [showNotificationsInForeground]: vẫn hiện thông báo khi app đang mở.
  /// - [handleBackgroundMessages]: tự đăng ký [tingPushBackgroundHandler] để hiện cuộc gọi khi app ở nền/đã tắt.
  ///   Đặt false nếu app có `FirebaseMessaging.onBackgroundMessage` riêng, rồi gọi [handleBackgroundMessage] trong đó.
  static Future<void> initialize({
    required String appId,
    required String serverUrl,
    bool? iosSandbox,
    TingPushCallStyle callStyle = const TingPushCallStyle(),
    bool requestPermission = true,
    bool showNotificationsInForeground = true,
    bool handleBackgroundMessages = true,
    bool logging = false,
  }) async {
    _appId = appId;
    _serverUrl = Uri.parse(serverUrl.endsWith('/') ? serverUrl : '$serverUrl/');
    _iosSandbox = iosSandbox ?? !kReleaseMode;
    _style = callStyle;
    _showInForeground = showNotificationsInForeground;
    _logging = logging;

    if (handleBackgroundMessages) {
      FirebaseMessaging.onBackgroundMessage(tingPushBackgroundHandler);
    }

    final prefs = await SharedPreferences.getInstance();
    // Lưu lại để background isolate (FCM khi app tắt) dùng đúng giao diện cuộc gọi.
    await prefs.setString(_kStyle, jsonEncode(callStyle.toJson()));

    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions
      ..clear()
      ..add(FlutterCallkitIncoming.onEvent.listen(_onCallkitEvent))
      ..add(FirebaseMessaging.onMessage.listen(_onForegroundMessage))
      ..add(FirebaseMessaging.onMessageOpenedApp.listen(_onRemoteOpened))
      ..add(FirebaseMessaging.instance.onTokenRefresh.listen((_) => _sync()));
    _channel.setMethodCallHandler(_onNativeCall);

    final messaging = FirebaseMessaging.instance;
    if (requestPermission) {
      await messaging.requestPermission();
    }
    if (Platform.isIOS) {
      await messaging.setForegroundNotificationPresentationOptions(
        alert: showNotificationsInForeground,
        badge: showNotificationsInForeground,
        sound: showNotificationsInForeground,
      );
      final voip = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      if (voip != null && voip.isNotEmpty) _voipToken = voip;
    }
    await _checkLaunchEvents();
    await _sync();
  }

  /// Gắn thiết bị với user trong hệ thống của bạn (gọi sau khi đăng nhập). Backend gửi theo External ID này.
  static Future<void> login(String externalUserId) async {
    await (await SharedPreferences.getInstance()).setString(_kUserId, externalUserId);
    await _sync();
  }

  /// Bỏ gắn user (gọi khi đăng xuất).
  static Future<void> logout() async {
    await (await SharedPreferences.getInstance()).remove(_kUserId);
    await _sync();
  }

  /// Thay toàn bộ tag của thiết bị (dùng để lọc khi gửi). `{}` = xoá hết tag.
  static Future<void> setTags(Map<String, String> tags) async {
    await (await SharedPreferences.getInstance()).setString(_kPendingTags, jsonEncode(tags));
    await _sync();
  }

  /// Ngừng nhận thông báo trên thiết bị này cho tới khi gọi [subscribe].
  static Future<void> unsubscribe() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUnsubscribed, true);
    final id = prefs.getString(_kDeviceId);
    if (id == null || _serverUrl == null) return;
    final response = await http.delete(_serverUrl!.resolve('api/v1/apps/$_appId/devices/$id'));
    if (response.statusCode >= 300) {
      throw TingPushException('Huỷ đăng ký lỗi ${response.statusCode}: ${response.body}');
    }
  }

  static Future<void> subscribe() async {
    await (await SharedPreferences.getInstance()).setBool(_kUnsubscribed, false);
    await _sync();
  }

  /// Tắt màn hình cuộc gọi / kết thúc cuộc gọi trên CallKit (vd đầu bên kia cúp máy, hoặc app tự cúp).
  static Future<void> endCall(String callId) => FlutterCallkitIncoming.endCall(callId);

  /// Báo cuộc gọi đã kết nối xong (iOS: CallKit bắt đầu đếm thời gian gọi).
  static Future<void> setCallConnected(String callId) => FlutterCallkitIncoming.setCallConnected(callId);

  /// Android 14+: app có được hiện màn hình cuộc gọi toàn màn hình khi máy khoá không.
  static Future<bool> canUseFullScreenIntent() async =>
      !Platform.isAndroid || await FlutterCallkitIncoming.canUseFullScreenIntent();

  /// Android 14+: mở cài đặt cho phép hiện toàn màn hình.
  static Future<void> requestFullScreenIntentPermission() async {
    if (Platform.isAndroid) await FlutterCallkitIncoming.requestFullIntentPermission();
  }

  /// Xử lý push khi app ở nền hoặc đã tắt: hiện màn hình cuộc gọi đến (Android) / tắt cuộc gọi khi nhận call_ended.
  /// SDK tự gọi qua [tingPushBackgroundHandler]; chỉ cần gọi thủ công nếu app có handler nền riêng.
  /// Trả về true nếu là push cuộc gọi.
  static Future<bool> handleBackgroundMessage(RemoteMessage message) async {
    final prefs = await SharedPreferences.getInstance();
    final style = prefs.getString(_kStyle);
    if (style != null) _style = TingPushCallStyle.fromJson(jsonDecode(style) as Map<String, dynamic>);
    return _handleCallData(message.data);
  }

  // ---------------- Nội bộ ----------------

  static Future<void> _onForegroundMessage(RemoteMessage message) async {
    if (await _handleCallData(message.data)) return;
    final notification = _fromRemote(message);
    // iOS tự hiện banner (setForegroundNotificationPresentationOptions); Android do plugin hiện.
    if (Platform.isAndroid && _showInForeground && message.notification != null) {
      try {
        await _channel.invokeMethod<void>('showNotification', {
          'title': notification.title,
          'body': notification.body,
          'data': notification.data,
          'channelName': _style.notificationChannelName,
        });
      } on Exception catch (e) {
        _log('Không hiện được thông báo: $e');
      }
    }
    _received.add(notification);
  }

  static void _onRemoteOpened(RemoteMessage message) {
    if (message.data['type'] == 'incoming_call') return;
    _opened.add(_fromRemote(message));
  }

  /// Người dùng bấm thông báo do plugin Android hiện (lúc app đang mở).
  static Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'onOpened' && call.arguments is Map) {
      _opened.add(TingPushNotification.fromMap(call.arguments as Map));
    }
  }

  static TingPushNotification _fromRemote(RemoteMessage message) => TingPushNotification(
        title: message.notification?.title,
        body: message.notification?.body,
        data: {
          for (final e in message.data.entries)
            if (e.value != null) e.key: e.value.toString(),
        },
      );

  /// App được mở bằng cách bấm thông báo / bấm Nghe lúc đang tắt: phát sự kiện tương ứng (một lần mỗi lần chạy).
  static Future<void> _checkLaunchEvents() async {
    if (_launchEventsChecked) return;
    _launchEventsChecked = true;
    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _onRemoteOpened(initial);
      if (Platform.isAndroid) {
        final local = await _channel.invokeMapMethod<String, dynamic>('takeInitialOpened');
        if (local != null) _opened.add(TingPushNotification.fromMap(local));
      }
      final accepted = await getAcceptedCall();
      if (accepted != null) _emitCall(TingPushCallAction.accepted, accepted);
    } on Exception catch (e) {
      _log('Đọc sự kiện lúc mở app lỗi: $e');
    }
  }

  static Future<bool> _handleCallData(Map<String, dynamic> data) async {
    switch (data['type']) {
      case 'incoming_call':
        // iOS nhận cuộc gọi qua VoIP push (plugin native), không đi qua đây.
        if (!Platform.isAndroid) return true;
        final call = TingPushCall.fromData(data);
        if (call == null) return true;
        _calls[call.id] = call;
        await FlutterCallkitIncoming.showCallkitIncoming(_params(call));
        return true;
      case 'call_ended':
        final id = data['call_id'] as String?;
        if (id == null) return true;
        final active = await FlutterCallkitIncoming.activeCalls();
        final match = active.where((c) => c.id == id).firstOrNull;
        await FlutterCallkitIncoming.endCall(id);
        if (match != null && !match.isAccepted && _style.showMissedCallNotification) {
          await FlutterCallkitIncoming.showMissCallNotification(match);
        }
        return true;
      default:
        return false;
    }
  }

  static CallKitParams _params(TingPushCall call) => CallKitParams(
        id: call.id,
        nameCaller: call.callerName.isEmpty ? call.handle : call.callerName,
        appName: _style.appName,
        avatar: call.avatarUrl,
        handle: call.handle,
        type: call.isVideo ? 1 : 0,
        duration: call.timeoutSeconds * 1000,
        extra: call.data,
        missedCallNotification: NotificationParams(
          showNotification: _style.showMissedCallNotification,
          subtitle: _style.missedCallText,
          isShowCallback: false,
        ),
        android: AndroidParams(
          isCustomNotification: true,
          isShowLogo: false,
          isShowFullLockedScreen: true,
          isImportant: true,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: _style.backgroundColor,
          actionColor: _style.actionColor,
          textColor: '#ffffff',
          incomingCallNotificationChannelName: _style.incomingCallChannelName,
          missedCallNotificationChannelName: _style.missedCallChannelName,
          textAccept: _style.textAccept,
          textDecline: _style.textDecline,
        ),
        ios: IOSParams(
          iconName: _style.iosIconName,
          handleType: 'generic',
          supportsVideo: true,
          maximumCallGroups: 1,
          maximumCallsPerCallGroup: 1,
          ringtonePath: 'system_ringtone_default',
        ),
      );

  static TingPushCall _callFromParams(CallKitParams p) {
    final call = TingPushCall.fromData(p.extra) ??
        _calls[p.id] ??
        TingPushCall(
          id: p.id,
          callerName: p.nameCaller ?? '',
          handle: p.handle ?? '',
          avatarUrl: p.avatar,
          isVideo: p.type == 1,
        );
    _calls[call.id] = call;
    return call;
  }

  static void _emitCall(TingPushCallAction action, TingPushCall call) {
    // Cuộc gọi nghe lúc app tắt có thể báo cả qua event lẫn _checkLaunchEvents: chỉ phát một lần.
    if (action == TingPushCallAction.accepted && !_acceptedEmitted.add(call.id)) return;
    _callEvents.add(TingPushCallEvent(action, call));
    if (action != TingPushCallAction.incoming && action != TingPushCallAction.accepted) {
      _calls.remove(call.id);
      _acceptedEmitted.remove(call.id);
    }
  }

  static void _onCallkitEvent(CallEvent? event) {
    switch (event) {
      case CallEventActionCallIncoming(:final callKitParams):
        _emitCall(TingPushCallAction.incoming, _callFromParams(callKitParams));
      case CallEventActionCallAccept(:final callKitParams):
        _emitCall(TingPushCallAction.accepted, _callFromParams(callKitParams));
      case CallEventActionCallDecline(:final callKitParams):
        _emitCall(TingPushCallAction.declined, _callFromParams(callKitParams));
      case CallEventActionCallEnded(:final callKitParams):
        _emitCall(TingPushCallAction.ended, _callFromParams(callKitParams));
      case CallEventActionCallTimeout(:final id):
        _emitCall(TingPushCallAction.timeout, _calls[id] ?? TingPushCall(id: id));
      case CallEventActionDidUpdateDevicePushTokenVoip():
        _refreshVoipToken();
      default:
        break;
    }
  }

  static Future<void> _refreshVoipToken() async {
    final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP() ?? '';
    if (token == (_voipToken ?? '')) return;
    _voipToken = token; // "" = token đã bị huỷ → server xoá VoIP token.
    await _sync();
  }

  /// Đăng ký (upsert) thiết bị. Chạy tuần tự; gọi lặp lại an toàn.
  static Future<void> _sync() {
    _syncChain = _syncChain.then((_) => _doSync()).catchError((Object e) {
      _log('Đăng ký thiết bị lỗi: $e');
      _errors.add(e);
    });
    return _syncChain;
  }

  static Future<void> _doSync() async {
    final server = _serverUrl;
    if (server == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kUnsubscribed) ?? false) return;

    final token = await _pushToken();
    if (token == null) {
      _log('Chưa có push token, sẽ đăng ký lại khi token có.');
      return;
    }

    final tags = prefs.getString(_kPendingTags);
    final body = <String, Object?>{
      'platform': Platform.isIOS ? 'Ios' : 'Android',
      'token': token,
      'isSandbox': Platform.isIOS && _iosSandbox,
      // Server ghi đè externalUserId mỗi lần đăng ký nên luôn gửi giá trị hiện tại.
      'externalUserId': prefs.getString(_kUserId),
      'appVersion': (await PackageInfo.fromPlatform()).version,
      'language': PlatformDispatcher.instance.locale.languageCode,
      ...await _deviceInfo(),
      if (tags != null) 'tags': jsonDecode(tags),
      if (Platform.isIOS && _voipToken != null) 'voipToken': _voipToken,
    };

    final response = await http.post(
      server.resolve('api/v1/apps/$_appId/devices'),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(body),
    );
    if (response.statusCode >= 300) {
      throw TingPushException('TingPush API lỗi ${response.statusCode}: ${response.body}');
    }

    final id = (jsonDecode(response.body) as Map<String, dynamic>)['id'] as String;
    await prefs.setString(_kDeviceId, id);
    // Tag đổi trong lúc đang gửi thì giữ lại để lần sync sau gửi tiếp.
    if (tags != null && prefs.getString(_kPendingTags) == tags) await prefs.remove(_kPendingTags);
    _log('Đã đăng ký thiết bị $id');
    _registered.add(id);
  }

  /// iOS: APNs token (hex) vì server gửi thẳng tới APNs. Android: FCM token.
  static Future<String?> _pushToken() async {
    final messaging = FirebaseMessaging.instance;
    if (!Platform.isIOS) return messaging.getToken();
    // APNs token có thể chưa sẵn sàng ngay sau khi khởi động.
    for (var i = 0; i < 10; i++) {
      final token = await messaging.getAPNSToken();
      if (token != null) return token;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  static Future<Map<String, String>> _deviceInfo() async {
    final info = DeviceInfoPlugin();
    if (Platform.isIOS) {
      final ios = await info.iosInfo;
      return {'deviceModel': ios.utsname.machine, 'deviceOs': ios.systemVersion};
    }
    final android = await info.androidInfo;
    return {'deviceModel': '${android.manufacturer} ${android.model}', 'deviceOs': android.version.release};
  }

  static void _log(String message) {
    if (_logging) debugPrint('[TingPush] $message');
  }
}

/// Broadcast stream giữ lại sự kiện phát ra khi chưa có ai nghe, rồi gửi cho listener đầu tiên
/// (vd bấm thông báo mở app trước khi màn hình gắn listener).
class _BufferedStream<T> {
  _BufferedStream() {
    _controller = StreamController<T>.broadcast(onListen: _flush);
  }

  late final StreamController<T> _controller;
  final List<T> _pending = [];

  Stream<T> get stream => _controller.stream;

  void add(T event) {
    if (_controller.hasListener) {
      _controller.add(event);
    } else {
      _pending.add(event);
    }
  }

  void _flush() => scheduleMicrotask(() {
        final events = List.of(_pending);
        _pending.clear();
        events.forEach(_controller.add);
      });
}
