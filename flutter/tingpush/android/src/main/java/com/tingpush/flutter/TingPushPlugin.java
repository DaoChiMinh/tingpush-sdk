package com.tingpush.flutter;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;

import androidx.annotation.NonNull;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Android: hiện thông báo khi app đang mở (FCM không tự hiện trong trường hợp này) và báo lại cho Dart khi
 * người dùng bấm vào thông báo đó. Thông báo FCM tự hiện lúc app ở nền do firebase_messaging xử lý.
 */
public class TingPushPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
        PluginRegistry.NewIntentListener {
    private static final String EXTRA_OPENED = "com.tingpush.flutter.OPENED";
    private static final String EXTRA_TITLE = "com.tingpush.flutter.TITLE";
    private static final String EXTRA_BODY = "com.tingpush.flutter.BODY";
    private static final String EXTRA_DATA = "com.tingpush.flutter.DATA";
    private static final String CHANNEL_ID = "tingpush_default";

    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding activityBinding;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "tingpush");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "showNotification":
                Map<String, String> data = call.argument("data");
                show(call.argument("title"), call.argument("body"), data == null ? new HashMap<>() : data,
                        call.argument("channelName"));
                result.success(null);
                break;
            case "takeInitialOpened":
                Activity activity = activityBinding == null ? null : activityBinding.getActivity();
                result.success(activity == null ? null : consume(activity.getIntent()));
                break;
            default:
                result.notImplemented();
        }
    }

    // ---------------- Activity ----------------

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityBinding = binding;
        binding.addOnNewIntentListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) activityBinding.removeOnNewIntentListener(this);
        activityBinding = null;
    }

    @Override
    public boolean onNewIntent(@NonNull Intent intent) {
        Map<String, Object> opened = consume(intent);
        if (opened != null && channel != null) channel.invokeMethod("onOpened", opened);
        return false;
    }

    /** Thông tin thông báo nếu intent mở app từ thông báo do plugin hiện; xoá extra để không báo lặp. */
    private static Map<String, Object> consume(Intent intent) {
        if (intent == null || !intent.getBooleanExtra(EXTRA_OPENED, false)) return null;
        Map<String, Object> opened = new HashMap<>();
        opened.put("title", intent.getStringExtra(EXTRA_TITLE));
        opened.put("body", intent.getStringExtra(EXTRA_BODY));
        Map<String, String> data = new HashMap<>();
        Bundle bundle = intent.getBundleExtra(EXTRA_DATA);
        if (bundle != null) {
            for (String key : bundle.keySet()) {
                String value = bundle.getString(key);
                if (value != null) data.put(key, value);
            }
        }
        opened.put("data", data);
        intent.removeExtra(EXTRA_OPENED);
        intent.removeExtra(EXTRA_TITLE);
        intent.removeExtra(EXTRA_BODY);
        intent.removeExtra(EXTRA_DATA);
        return opened;
    }

    // ---------------- Hiện thông báo ----------------

    @SuppressLint("MissingPermission")
    private void show(String title, String body, Map<String, String> data, String channelName) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager manager = context.getSystemService(NotificationManager.class);
            manager.createNotificationChannel(new NotificationChannel(CHANNEL_ID,
                    channelName == null ? "Thông báo" : channelName, NotificationManager.IMPORTANCE_HIGH));
        }

        int id = (int) (System.currentTimeMillis() & 0x7fffffff);
        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(openAppIntent(title, body, data, id));
        applyIcon(builder);

        try {
            NotificationManagerCompat.from(context).notify(id, builder.build());
        } catch (SecurityException e) {
            // Chưa được cấp quyền POST_NOTIFICATIONS (Android 13+).
        }
    }

    private PendingIntent openAppIntent(String title, String body, Map<String, String> data, int requestCode) {
        Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (launch == null) return null;
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        Bundle bundle = new Bundle();
        for (Map.Entry<String, String> e : data.entrySet()) bundle.putString(e.getKey(), e.getValue());
        launch.putExtra(EXTRA_OPENED, true);
        launch.putExtra(EXTRA_TITLE, title);
        launch.putExtra(EXTRA_BODY, body);
        launch.putExtra(EXTRA_DATA, bundle);
        return PendingIntent.getActivity(context, requestCode, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /** Dùng cùng icon/màu với thông báo FCM (meta-data default_notification_icon/color), không có thì icon app. */
    private void applyIcon(NotificationCompat.Builder builder) {
        int icon = 0;
        int color = 0;
        try {
            ApplicationInfo info = context.getPackageManager()
                    .getApplicationInfo(context.getPackageName(), PackageManager.GET_META_DATA);
            if (info.metaData != null) {
                icon = info.metaData.getInt("com.google.firebase.messaging.default_notification_icon", 0);
                color = info.metaData.getInt("com.google.firebase.messaging.default_notification_color", 0);
            }
            if (icon == 0) icon = info.icon;
        } catch (PackageManager.NameNotFoundException ignored) {
        }
        builder.setSmallIcon(icon != 0 ? icon : android.R.drawable.ic_dialog_info);
        if (color != 0) builder.setColor(ContextCompat.getColor(context, color));
    }
}
