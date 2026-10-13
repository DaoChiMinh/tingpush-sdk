package com.tingpush.sdk

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Nút "Từ chối" trên notification cuộc gọi. */
internal class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_DECLINE) return
        val call = CallInfo.fromIntent(intent) ?: return
        CallNotifier.declined(context, call)
    }

    companion object {
        const val ACTION_DECLINE = "com.tingpush.sdk.DECLINE"
    }
}
