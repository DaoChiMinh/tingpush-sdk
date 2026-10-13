/// Thông báo nhận được / người dùng bấm vào.
class TingPushNotification {
  const TingPushNotification({this.title, this.body, this.data = const {}});

  final String? title;
  final String? body;

  /// Các key "data" backend gửi kèm (vd screen, id…).
  final Map<String, String> data;

  static TingPushNotification fromMap(Map<dynamic, dynamic> map) => TingPushNotification(
        title: map['title'] as String?,
        body: map['body'] as String?,
        data: _stringMap(map['data'] as Map<dynamic, dynamic>?),
      );

  static Map<String, String> _stringMap(Map<dynamic, dynamic>? raw) => {
        for (final e in (raw ?? const {}).entries)
          if (e.key is String && e.value != null) e.key as String: e.value.toString(),
      };

  @override
  String toString() => 'TingPushNotification($title, $data)';
}

/// Thông tin cuộc gọi đọc từ payload push (giống nhau trên iOS và Android).
class TingPushCall {
  const TingPushCall({
    required this.id,
    this.callerName = '',
    this.handle = '',
    this.avatarUrl,
    this.isVideo = false,
    this.timeoutSeconds = defaultTimeoutSeconds,
    this.data = const {},
  });

  static const int defaultTimeoutSeconds = 45;

  /// call_id do server gửi (UUID).
  final String id;
  final String callerName;
  final String handle;
  final String? avatarUrl;
  final bool isVideo;

  /// Thời gian đổ chuông tối đa (giây).
  final int timeoutSeconds;

  /// Toàn bộ payload, gồm cả các key "data" mà backend gửi kèm (vd room, token cuộc gọi…).
  final Map<String, String> data;

  static TingPushCall? fromData(Map<dynamic, dynamic>? raw) {
    if (raw == null) return null;
    final data = <String, String>{
      for (final e in raw.entries)
        if (e.key is String && e.key != 'aps' && e.value != null) e.key as String: e.value.toString(),
    };
    final id = data['call_id'];
    if (id == null || id.isEmpty) return null;
    final avatar = data['caller_avatar'];
    return TingPushCall(
      id: id,
      callerName: data['caller_name'] ?? '',
      handle: data['caller_handle'] ?? '',
      avatarUrl: avatar == null || avatar.isEmpty ? null : avatar,
      isVideo: data['is_video'] == 'true',
      timeoutSeconds: int.tryParse(data['timeout'] ?? '') ?? defaultTimeoutSeconds,
      data: data,
    );
  }

  @override
  String toString() => 'TingPushCall($id, $callerName)';
}

enum TingPushCallAction {
  /// Màn hình cuộc gọi đã hiện (đang đổ chuông).
  incoming,

  /// Người dùng bấm nghe: kết nối cuộc gọi (WebRTC/SIP…) tại đây.
  accepted,

  /// Người dùng từ chối khi đang đổ chuông.
  declined,

  /// Cuộc gọi kết thúc (sau khi đã nghe, hoặc server báo call_ended).
  ended,

  /// Hết thời gian đổ chuông mà không nghe.
  timeout,
}

class TingPushCallEvent {
  const TingPushCallEvent(this.action, this.call);

  final TingPushCallAction action;
  final TingPushCall call;

  @override
  String toString() => 'TingPushCallEvent(${action.name}, $call)';
}

/// Chữ và giao diện màn hình cuộc gọi.
class TingPushCallStyle {
  const TingPushCallStyle({
    this.appName = '',
    this.textAccept = 'Nghe',
    this.textDecline = 'Từ chối',
    this.missedCallText = 'Cuộc gọi nhỡ',
    this.showMissedCallNotification = true,
    this.backgroundColor = '#1C1C1E',
    this.actionColor = '#34C759',
    this.incomingCallChannelName = 'Cuộc gọi đến',
    this.missedCallChannelName = 'Cuộc gọi nhỡ',
    this.notificationChannelName = 'Thông báo',
    this.iosIconName,
  });

  /// Tên app trên màn hình cuộc gọi Android.
  final String appName;
  final String textAccept;
  final String textDecline;
  final String missedCallText;
  final bool showMissedCallNotification;
  final String backgroundColor;
  final String actionColor;
  final String incomingCallChannelName;
  final String missedCallChannelName;

  /// Android: tên kênh của thông báo thường hiện khi app đang mở.
  final String notificationChannelName;

  /// Tên ảnh template trong Assets.xcassets cho màn hình CallKit.
  final String? iosIconName;

  Map<String, Object?> toJson() => {
        'appName': appName,
        'textAccept': textAccept,
        'textDecline': textDecline,
        'missedCallText': missedCallText,
        'showMissedCallNotification': showMissedCallNotification,
        'backgroundColor': backgroundColor,
        'actionColor': actionColor,
        'incomingCallChannelName': incomingCallChannelName,
        'missedCallChannelName': missedCallChannelName,
        'notificationChannelName': notificationChannelName,
        'iosIconName': iosIconName,
      };

  static TingPushCallStyle fromJson(Map<String, dynamic> json) => TingPushCallStyle(
        appName: json['appName'] as String? ?? '',
        textAccept: json['textAccept'] as String? ?? 'Nghe',
        textDecline: json['textDecline'] as String? ?? 'Từ chối',
        missedCallText: json['missedCallText'] as String? ?? 'Cuộc gọi nhỡ',
        showMissedCallNotification: json['showMissedCallNotification'] as bool? ?? true,
        backgroundColor: json['backgroundColor'] as String? ?? '#1C1C1E',
        actionColor: json['actionColor'] as String? ?? '#34C759',
        incomingCallChannelName: json['incomingCallChannelName'] as String? ?? 'Cuộc gọi đến',
        missedCallChannelName: json['missedCallChannelName'] as String? ?? 'Cuộc gọi nhỡ',
        notificationChannelName: json['notificationChannelName'] as String? ?? 'Thông báo',
        iosIconName: json['iosIconName'] as String?,
      );
}

class TingPushException implements Exception {
  TingPushException(this.message);

  final String message;

  @override
  String toString() => 'TingPushException: $message';
}
