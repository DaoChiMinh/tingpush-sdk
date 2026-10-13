/** Thông tin cuộc gọi đọc từ payload push (giống nhau trên iOS và Android). */
export interface TingPushCall {
  /** call_id do server gửi (UUID). */
  id: string;
  callerName: string;
  handle: string;
  avatarUrl?: string;
  isVideo: boolean;
  /** Thời gian đổ chuông tối đa (giây). */
  timeoutSeconds: number;
  /** Toàn bộ payload, gồm cả các key "data" mà backend gửi kèm (vd room, token cuộc gọi…). */
  data: Record<string, string>;
}

export type TingPushCallAction =
  /** Màn hình cuộc gọi đã hiện (đang đổ chuông). */
  | 'incoming'
  /** Người dùng bấm nghe: kết nối cuộc gọi (WebRTC/SIP…) tại đây. */
  | 'accepted'
  /** Người dùng từ chối khi đang đổ chuông. */
  | 'declined'
  /** Cuộc gọi kết thúc sau khi đã nghe (người dùng cúp máy hoặc server báo call_ended). */
  | 'ended'
  /** Hết thời gian đổ chuông, hoặc người gọi huỷ trước khi nghe. */
  | 'missed';

export interface TingPushCallEvent {
  action: TingPushCallAction;
  call: TingPushCall;
}

export interface TingPushOptions {
  /** App ID của dự án trên TingPush. */
  appId: string;
  /** Địa chỉ server TingPush, mặc định https://tingpush.com. Chỉ cần đổi khi tự host server hoặc test với server khác. */
  serverUrl?: string;
  /** Tên app trên màn hình cuộc gọi. */
  appName: string;
  /** iOS: môi trường APNs. Mặc định __DEV__ = sandbox. */
  iosSandbox?: boolean;
  /** Xin quyền thông báo ngay khi khởi tạo. Mặc định true. */
  requestPermission?: boolean;
  /** Chữ trên hộp thoại xin quyền tài khoản gọi điện (Android). */
  androidPermissionTexts?: {
    alertTitle: string;
    alertDescription: string;
    cancelButton: string;
    okButton: string;
  };
  logging?: boolean;
}

/** Thông báo nhận được / người dùng bấm vào. */
export interface TingPushNotification {
  title?: string;
  body?: string;
  /** Các key "data" backend gửi kèm (vd screen, id…). */
  data: Record<string, string>;
}

export interface TingPushListeners {
  onDeviceRegistered?: (deviceId: string) => void;
  /** Thông báo / data message khi app đang mở (không gồm push cuộc gọi). */
  onNotificationReceived?: (notification: TingPushNotification) => void;
  /** Người dùng bấm vào thông báo, dù app đang mở, chạy nền hay đã tắt hẳn. */
  onNotificationOpened?: (notification: TingPushNotification) => void;
  onCallEvent?: (event: TingPushCallEvent) => void;
  onError?: (error: unknown) => void;
}
