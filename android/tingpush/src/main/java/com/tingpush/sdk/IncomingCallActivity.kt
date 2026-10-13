package com.tingpush.sdk

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.lang.ref.WeakReference

/**
 * Màn hình cuộc gọi đến toàn màn hình, hiện cả khi máy đang khoá (qua full-screen intent).
 * Cũng nhận hành động "Nghe" từ notification: mở app chính kèm thông tin cuộc gọi.
 */
class IncomingCallActivity : Activity() {
    private var call: CallInfo? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    override fun onDestroy() {
        if (current?.get() === this) current = null
        super.onDestroy()
    }

    private fun handle(intent: Intent?) {
        val call = CallInfo.fromIntent(intent) ?: return finish()
        this.call = call
        if (intent?.action == ACTION_ACCEPT) {
            accept(call)
            return
        }
        current = WeakReference(this)
        setContentView(buildView(call))
    }

    private fun accept(call: CallInfo) {
        CallNotifier.accepted(this, call)
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return finish()
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        launch.putExtra(TingPush.EXTRA_ACCEPTED, true)
        launch.putExtra(CallInfo.EXTRA_CALL, call.toBundle())

        fun openApp() {
            startActivity(launch)
            finish()
        }

        // Màn hình khoá có mật khẩu: yêu cầu mở khoá, xong (hoặc người dùng bỏ qua) mới mở app.
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && keyguard.isKeyguardLocked) {
            keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() = openApp()
                override fun onDismissCancelled() = openApp()
                override fun onDismissError() = openApp()
            })
        } else {
            openApp()
        }
    }

    private fun decline(call: CallInfo) {
        CallNotifier.declined(this, call)
        finish()
    }

    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    /** Giao diện dựng bằng code để SDK không cần file layout/resource. */
    private fun buildView(call: CallInfo): LinearLayout {
        val texts = TingPush.options.callTexts
        val dp = resources.displayMetrics.density
        val name = call.callerName.ifBlank { call.handle }

        fun text(value: String, size: Float, alpha: Float = 1f, bold: Boolean = false) = TextView(this).apply {
            this.text = value
            textSize = size
            setTextColor(Color.WHITE)
            this.alpha = alpha
            gravity = Gravity.CENTER
            if (bold) typeface = Typeface.DEFAULT_BOLD
        }

        fun roundButton(label: String, color: Int, onClick: () -> Unit) = Button(this).apply {
            text = label
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = 40 * dp
                setColor(color)
            }
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(0, (64 * dp).toInt(), 1f).apply {
                setMargins((12 * dp).toInt(), 0, (12 * dp).toInt(), 0)
            }
        }

        val avatar = text(name.take(1).uppercase().ifBlank { "?" }, 40f, bold = true).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#3A3A3C"))
            }
            layoutParams = LinearLayout.LayoutParams((110 * dp).toInt(), (110 * dp).toInt()).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = (20 * dp).toInt()
            }
        }

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(roundButton(texts.decline, Color.parseColor("#FF3B30")) { decline(call) })
            addView(roundButton(texts.answer, Color.parseColor("#34C759")) { accept(call) })
        }

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(Color.parseColor("#1C1C1E"))
            setPadding((24 * dp).toInt(), (120 * dp).toInt(), (24 * dp).toInt(), (64 * dp).toInt())
            addView(avatar)
            addView(text(name, 28f, bold = true))
            if (call.handle.isNotBlank() && call.handle != name) addView(text(call.handle, 16f, 0.7f))
            addView(text(if (call.isVideo) texts.incomingVideo else texts.incomingAudio, 16f, 0.7f))
            addView(LinearLayout(context).apply {
                layoutParams = LinearLayout.LayoutParams(1, 0, 1f)
            })
            addView(buttons)
        }
    }

    companion object {
        internal const val ACTION_SHOW = "com.tingpush.sdk.SHOW_CALL"
        internal const val ACTION_ACCEPT = "com.tingpush.sdk.ACCEPT_CALL"

        private var current: WeakReference<IncomingCallActivity>? = null

        internal fun intent(context: Context, call: CallInfo, action: String): Intent =
            Intent(context, IncomingCallActivity::class.java)
                .setAction(action)
                .putExtra(CallInfo.EXTRA_CALL, call.toBundle())
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)

        /** Đóng màn hình cuộc gọi nếu đang hiện đúng cuộc gọi này. */
        internal fun finishCall(callId: String) {
            val activity = current?.get() ?: return
            activity.runOnUiThread {
                if (activity.call?.id == callId) activity.finish()
            }
        }
    }
}
