using Android.App;

// Quyền SDK cần; được gộp vào AndroidManifest của app khi build.
[assembly: UsesPermission("android.permission.INTERNET")]
// Android 13+: hiển thị thông báo.
[assembly: UsesPermission("android.permission.POST_NOTIFICATIONS")]
// Hiện màn hình cuộc gọi khi máy đang khoá. Android 14+: Google Play chỉ tự cấp cho app gọi điện/báo thức.
[assembly: UsesPermission("android.permission.USE_FULL_SCREEN_INTENT")]
[assembly: UsesPermission("android.permission.VIBRATE")]
[assembly: UsesPermission("android.permission.WAKE_LOCK")]
