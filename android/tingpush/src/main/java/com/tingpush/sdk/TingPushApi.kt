package com.tingpush.sdk

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** Gọi REST API thiết bị của TingPush (chỉ cần App ID). Chạy đồng bộ, gọi từ background thread. */
internal class TingPushApi(private val serverUrl: String, private val appId: String) {

    /** Upsert thiết bị theo token, trả về device id. */
    fun register(body: JSONObject): String {
        val response = send("POST", "api/v1/apps/$appId/devices", body.toString())
        return JSONObject(response).getString("id")
    }

    fun unsubscribe(deviceId: String) {
        send("DELETE", "api/v1/apps/$appId/devices/$deviceId", null)
    }

    private fun send(method: String, path: String, body: String?): String {
        val connection = URL(serverUrl.trimEnd('/') + "/" + path).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 15_000
            connection.readTimeout = 20_000
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            if (status !in 200..299) throw TingPushException("TingPush API lỗi $status: $text")
            return text
        } finally {
            connection.disconnect()
        }
    }
}
