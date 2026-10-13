import AsyncStorage from '@react-native-async-storage/async-storage';
import messaging, { FirebaseMessagingTypes } from '@react-native-firebase/messaging';
import { NativeModules, Platform } from 'react-native';
import RNCallKeep from 'react-native-callkeep';
import DeviceInfo from 'react-native-device-info';
import VoipPushNotification from 'react-native-voip-push-notification';

import type {
  TingPushCall,
  TingPushCallAction,
  TingPushListeners,
  TingPushNotification,
  TingPushOptions,
} from './types';

export * from './types';

const KEY_DEVICE_ID = 'tingpush.deviceId';
const KEY_USER_ID = 'tingpush.externalUserId';
const KEY_PENDING_TAGS = 'tingpush.pendingTags';
const KEY_UNSUBSCRIBED = 'tingpush.unsubscribed';
const KEY_OPTIONS = 'tingpush.options';
const KEY_ACCEPTED = 'tingpush.acceptedCall';
const DEFAULT_TIMEOUT_SECONDS = 45;

/** Địa chỉ server TingPush mặc định. */
export const DEFAULT_SERVER_URL = 'https://tingpush.com';

/** Lý do kết thúc cuộc gọi của RNCallKeep.reportEndCallWithUUID. */
const END_REASON_REMOTE_ENDED = 2;
const END_REASON_UNANSWERED = 3;

let options: TingPushOptions | undefined;
let listeners: TingPushListeners = {};
let voipToken: string | undefined;
let syncChain: Promise<void> = Promise.resolve();
let callKeepReady: Promise<void> | undefined;
let callKeepListenersAdded = false;
const unsubscribers: Array<() => void> = [];

/** Cuộc gọi đang đổ chuông / đang nghe, theo call id. */
const calls = new Map<string, { call: TingPushCall; answered: boolean; timer?: ReturnType<typeof setTimeout> }>();
/** call_ended tới trước khi cuộc gọi hiện (mạng chậm): không đổ chuông nữa. */
const endedBeforeShown = new Set<string>();

function log(message: string) {
  if (options?.logging) console.log(`[TingPush] ${message}`);
}

function emitError(error: unknown) {
  log(`Lỗi: ${String(error)}`);
  listeners.onError?.(error);
}

/** Đọc thông tin cuộc gọi từ payload push. */
export function parseCall(raw: Record<string, unknown> | undefined | null): TingPushCall | undefined {
  if (!raw) return undefined;
  const data: Record<string, string> = {};
  for (const [key, value] of Object.entries(raw)) {
    if (key !== 'aps' && value != null) data[key] = String(value);
  }
  const id = data.call_id;
  if (!id) return undefined;
  return {
    id,
    callerName: data.caller_name ?? '',
    handle: data.caller_handle ?? '',
    avatarUrl: data.caller_avatar || undefined,
    isVideo: data.is_video === 'true',
    timeoutSeconds: Number(data.timeout) || DEFAULT_TIMEOUT_SECONDS,
    data,
  };
}

function emitCall(action: TingPushCallAction, call: TingPushCall) {
  listeners.onCallEvent?.({ action, call });
}

// ---------------- CallKit / ConnectionService ----------------

function setupCallKeep(opts: TingPushOptions): Promise<void> {
  if (!callKeepReady) {
    const texts = opts.androidPermissionTexts ?? {
      alertTitle: 'Cho phép nhận cuộc gọi',
      alertDescription: 'Ứng dụng cần quyền tài khoản gọi điện để hiện cuộc gọi đến.',
      cancelButton: 'Huỷ',
      okButton: 'Đồng ý',
    };
    callKeepReady = RNCallKeep.setup({
      ios: {
        appName: opts.appName,
        supportsVideo: true,
        maximumCallGroups: '1',
        maximumCallsPerCallGroup: '1',
        includesCallsInRecents: true,
      },
      android: {
        ...texts,
        additionalPermissions: [],
        selfManaged: false,
        foregroundService: {
          channelId: 'tingpush_call',
          channelName: opts.appName,
          notificationTitle: opts.appName,
        },
      },
    }).then(() => {
      if (Platform.OS === 'android') RNCallKeep.setAvailable(true);
    });
  }
  addCallKeepListeners();
  return callKeepReady;
}

function addCallKeepListeners() {
  if (callKeepListenersAdded) return;
  callKeepListenersAdded = true;

  RNCallKeep.addEventListener('didDisplayIncomingCall', ({ callUUID, payload }) => {
    // iOS: AppDelegate đã báo CallKit từ VoIP push; payload là dictionaryPayload của push.
    const call = parseCall(payload as Record<string, unknown>) ?? calls.get(callUUID.toLowerCase())?.call;
    if (call) onCallShown(call);
  });
  RNCallKeep.addEventListener('answerCall', ({ callUUID }) => {
    const entry = calls.get(callUUID.toLowerCase());
    if (!entry) return;
    entry.answered = true;
    if (entry.timer) clearTimeout(entry.timer);
    if (Platform.OS === 'android') {
      RNCallKeep.setCurrentCallActive(callUUID);
      RNCallKeep.backToForeground();
    }
    // App có thể đang khởi động lại (Android mở app sau khi bấm nghe): lưu lại để getAcceptedCall() lấy.
    AsyncStorage.setItem(KEY_ACCEPTED, JSON.stringify(entry.call)).catch(emitError);
    emitCall('accepted', entry.call);
  });
  RNCallKeep.addEventListener('endCall', ({ callUUID }) => {
    const id = callUUID.toLowerCase();
    const entry = calls.get(id);
    if (!entry) return;
    calls.delete(id);
    if (entry.timer) clearTimeout(entry.timer);
    emitCall(entry.answered ? 'ended' : 'declined', entry.call);
  });
}

function onCallShown(call: TingPushCall) {
  const id = call.id.toLowerCase();
  if (calls.has(id)) return;
  if (endedBeforeShown.delete(id)) {
    RNCallKeep.reportEndCallWithUUID(call.id, END_REASON_REMOTE_ENDED);
    return;
  }
  const entry: { call: TingPushCall; answered: boolean; timer?: ReturnType<typeof setTimeout> } = {
    call,
    answered: false,
  };
  entry.timer = setTimeout(() => {
    if (entry.answered || !calls.has(id)) return;
    calls.delete(id);
    RNCallKeep.reportEndCallWithUUID(call.id, END_REASON_UNANSWERED);
    emitCall('missed', call);
  }, call.timeoutSeconds * 1000);
  calls.set(id, entry);
  emitCall('incoming', call);
}

/** Xử lý push cuộc gọi. Trả về true nếu là push cuộc gọi. */
async function handleCallData(data: Record<string, string> | undefined): Promise<boolean> {
  switch (data?.type) {
    case 'incoming_call': {
      // iOS nhận cuộc gọi qua VoIP push (AppDelegate), không đi qua FCM.
      if (Platform.OS !== 'android') return true;
      const call = parseCall(data);
      if (!call || !options) return true;
      await setupCallKeep(options);
      if (endedBeforeShown.delete(call.id.toLowerCase())) return true;
      RNCallKeep.displayIncomingCall(call.id, call.handle || call.callerName, call.callerName, 'generic', call.isVideo);
      onCallShown(call);
      return true;
    }
    case 'call_ended': {
      const id = data.call_id?.toLowerCase();
      if (!id) return true;
      const entry = calls.get(id);
      if (!entry) {
        endedBeforeShown.add(id);
        return true;
      }
      calls.delete(id);
      if (entry.timer) clearTimeout(entry.timer);
      RNCallKeep.reportEndCallWithUUID(entry.call.id, END_REASON_REMOTE_ENDED);
      emitCall(entry.answered ? 'ended' : 'missed', entry.call);
      return true;
    }
    default:
      return false;
  }
}

// ---------------- Đăng ký thiết bị ----------------

async function pushToken(): Promise<string | undefined> {
  if (Platform.OS !== 'ios') return messaging().getToken();
  // Server gửi thẳng tới APNs nên iOS dùng APNs token (hex). Token có thể chưa sẵn sàng ngay.
  for (let i = 0; i < 10; i++) {
    const token = await messaging().getAPNSToken();
    if (token) return token;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  return undefined;
}

async function doSync(): Promise<void> {
  if (!options) return;
  if ((await AsyncStorage.getItem(KEY_UNSUBSCRIBED)) === '1') return;
  const token = await pushToken();
  if (!token) {
    log('Chưa có push token, sẽ đăng ký lại khi token có.');
    return;
  }

  const tags = await AsyncStorage.getItem(KEY_PENDING_TAGS);
  const body: Record<string, unknown> = {
    platform: Platform.OS === 'ios' ? 'Ios' : 'Android',
    token,
    isSandbox: Platform.OS === 'ios' && (options.iosSandbox ?? __DEV__),
    // Server ghi đè externalUserId mỗi lần đăng ký nên luôn gửi giá trị hiện tại.
    externalUserId: await AsyncStorage.getItem(KEY_USER_ID),
    appVersion: DeviceInfo.getVersion(),
    language: deviceLanguage(),
    deviceModel: Platform.OS === 'ios' ? DeviceInfo.getDeviceId() : `${DeviceInfo.getBrand()} ${DeviceInfo.getModel()}`,
    deviceOs: DeviceInfo.getSystemVersion(),
  };
  if (tags) body.tags = JSON.parse(tags);
  if (Platform.OS === 'ios' && voipToken !== undefined) body.voipToken = voipToken;

  const response = await fetch(url(`api/v1/apps/${options.appId}/devices`), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`TingPush API lỗi ${response.status}: ${text}`);

  const id = JSON.parse(text).id as string;
  await AsyncStorage.setItem(KEY_DEVICE_ID, id);
  // Tag đổi trong lúc đang gửi thì giữ lại để lần sync sau gửi tiếp.
  if (tags && (await AsyncStorage.getItem(KEY_PENDING_TAGS)) === tags) await AsyncStorage.removeItem(KEY_PENDING_TAGS);
  log(`Đã đăng ký thiết bị ${id}`);
  listeners.onDeviceRegistered?.(id);
}

/** Đăng ký (upsert) thiết bị. Chạy tuần tự; gọi lặp lại an toàn. */
function sync(): Promise<void> {
  syncChain = syncChain.then(doSync).catch(emitError);
  return syncChain;
}

function url(path: string): string {
  return `${(options!.serverUrl ?? DEFAULT_SERVER_URL).replace(/\/+$/, '')}/${path}`;
}

function deviceLanguage(): string {
  const settings = NativeModules.SettingsManager?.settings;
  const locale: string | undefined =
    Platform.OS === 'ios'
      ? settings?.AppleLocale ?? settings?.AppleLanguages?.[0]
      : NativeModules.I18nManager?.localeIdentifier;
  return (locale ?? '').slice(0, 2);
}

function toNotification(message: FirebaseMessagingTypes.RemoteMessage): TingPushNotification {
  return {
    title: message.notification?.title,
    body: message.notification?.body,
    data: toStringRecord(message.data),
  };
}

function toStringRecord(data: { [key: string]: string | object } | undefined): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, value] of Object.entries(data ?? {})) {
    result[key] = typeof value === 'string' ? value : JSON.stringify(value);
  }
  return result;
}

// ---------------- API công khai ----------------

export const TingPush = {
  /** Gọi một lần khi app khởi động (trong component gốc hoặc index.js). */
  async initialize(opts: TingPushOptions, eventListeners: TingPushListeners = {}): Promise<void> {
    options = opts;
    listeners = eventListeners;
    // Lưu lại để handler nền (app đã tắt) dùng được.
    await AsyncStorage.setItem(KEY_OPTIONS, JSON.stringify(opts));

    unsubscribers.splice(0).forEach((fn) => fn());
    await setupCallKeep(opts);

    if (opts.requestPermission ?? true) {
      await messaging().requestPermission();
    }

    unsubscribers.push(
      messaging().onTokenRefresh(() => {
        sync();
      }),
      messaging().onMessage(async (message) => {
        if (await handleCallData(toStringRecord(message.data))) return;
        listeners.onNotificationReceived?.(toNotification(message));
      }),
      messaging().onNotificationOpenedApp((message) => {
        listeners.onNotificationOpened?.(toNotification(message));
      }),
    );

    const initial = await messaging().getInitialNotification();
    if (initial) listeners.onNotificationOpened?.(toNotification(initial));

    if (Platform.OS === 'ios') {
      VoipPushNotification.addEventListener('register', (token: string) => {
        log(`VoIP token: ${token}`);
        if (token === voipToken) return;
        voipToken = token;
        sync();
      });
      // Sự kiện xảy ra trước khi JS sẵn sàng (app được VoIP push đánh thức).
      VoipPushNotification.addEventListener('didLoadWithEvents', (events: Array<{ name: string; data: unknown }>) => {
        for (const { name, data } of events ?? []) {
          if (name === VoipPushNotification.RNVoipPushRemoteNotificationsRegisteredEvent && typeof data === 'string') {
            voipToken = data;
            sync();
          }
        }
      });
      VoipPushNotification.registerVoipToken();

      const initialEvents = await RNCallKeep.getInitialEvents();
      for (const { name, data } of initialEvents ?? []) {
        if (name === 'RNCallKeepDidDisplayIncomingCall') {
          const call = parseCall((data as { payload?: Record<string, unknown> }).payload);
          if (call) onCallShown(call);
        } else if (name === 'RNCallKeepPerformAnswerCallAction') {
          const entry = calls.get(String((data as { callUUID: string }).callUUID).toLowerCase());
          if (entry) {
            entry.answered = true;
            if (entry.timer) clearTimeout(entry.timer);
            emitCall('accepted', entry.call);
          }
        }
      }
      RNCallKeep.clearInitialEvents();
    }

    await sync();
  },

  /**
   * Gọi trong `messaging().setBackgroundMessageHandler(...)` ở index.js (trước AppRegistry).
   * Android: hiện màn hình cuộc gọi đến khi app ở nền/đã tắt. Trả về true nếu là push cuộc gọi.
   */
  async handleBackgroundMessage(message: FirebaseMessagingTypes.RemoteMessage): Promise<boolean> {
    if (!options) {
      const saved = await AsyncStorage.getItem(KEY_OPTIONS);
      if (saved) options = JSON.parse(saved);
    }
    return handleCallData(toStringRecord(message.data));
  },

  /** Gắn thiết bị với user trong hệ thống của bạn (gọi sau khi đăng nhập). */
  async login(externalUserId: string): Promise<void> {
    await AsyncStorage.setItem(KEY_USER_ID, externalUserId);
    await sync();
  },

  /** Bỏ gắn user (gọi khi đăng xuất). */
  async logout(): Promise<void> {
    await AsyncStorage.removeItem(KEY_USER_ID);
    await sync();
  },

  /** Thay toàn bộ tag của thiết bị (dùng để lọc khi gửi). {} = xoá hết tag. */
  async setTags(tags: Record<string, string>): Promise<void> {
    await AsyncStorage.setItem(KEY_PENDING_TAGS, JSON.stringify(tags));
    await sync();
  },

  /** Ngừng nhận thông báo trên thiết bị này cho tới khi gọi subscribe(). */
  async unsubscribe(): Promise<void> {
    await AsyncStorage.setItem(KEY_UNSUBSCRIBED, '1');
    const id = await AsyncStorage.getItem(KEY_DEVICE_ID);
    if (!id || !options) return;
    const response = await fetch(url(`api/v1/apps/${options.appId}/devices/${id}`), { method: 'DELETE' });
    if (!response.ok) throw new Error(`Huỷ đăng ký lỗi ${response.status}`);
  },

  async subscribe(): Promise<void> {
    await AsyncStorage.removeItem(KEY_UNSUBSCRIBED);
    await sync();
  },

  getDeviceId(): Promise<string | null> {
    return AsyncStorage.getItem(KEY_DEVICE_ID);
  },

  /** Cuộc gọi người dùng đã bấm nghe trước khi app mở xong (Android). Lấy một lần lúc khởi động. */
  async getAcceptedCall(): Promise<TingPushCall | undefined> {
    const saved = await AsyncStorage.getItem(KEY_ACCEPTED);
    if (!saved) return undefined;
    await AsyncStorage.removeItem(KEY_ACCEPTED);
    return JSON.parse(saved);
  },

  /** Kết thúc cuộc gọi (app tự cúp máy, hoặc đầu bên kia đã cúp qua kênh signaling của bạn). */
  endCall(callId: string): void {
    RNCallKeep.endCall(callId);
  },
};

export default TingPush;
