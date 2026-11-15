package com.xadan.qyriptalk

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter <-> yerel (Android) köprüsü.
 * Arka plan servisi (KeepAliveService + ChatWatcher) uygulama kapalıyken de Firebase'i dinler,
 * WhatsApp gibi sesli mesaj bildirimi ve tam ekran zil sesli arama gösterir.
 */
class MainActivity : FlutterActivity() {

    companion object {
        /** Uygulama ekranda mı? (Ekrandayken bildirimleri Flutter tarafı yönetir.) */
        @JvmField
        @Volatile
        var visible: Boolean = false

        private var channel: MethodChannel? = null
        private val main = Handler(Looper.getMainLooper())

        /** Yerel taraftan Flutter'a olay gönderir (uygulama açıksa). */
        @JvmStatic
        fun sendAction(action: String, callId: String?, convKey: String?) {
            main.post {
                try {
                    channel?.invokeMethod(
                        "onAction",
                        mapOf("action" to action, "callId" to callId, "convKey" to convKey)
                    )
                } catch (e: Exception) {
                }
            }
        }
    }

    private var pendingLaunch: Map<String, String?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLaunch = describe(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val d = describe(intent) ?: return
        sendAction(d["action"] ?: "", d["callId"], d["convKey"])
    }

    override fun onResume() {
        super.onResume()
        visible = true
    }

    override fun onPause() {
        visible = false
        super.onPause()
    }

    /** Bildirimden gelen intent'i Flutter'ın anlayacağı olaya çevirir. */
    private fun describe(i: Intent?): Map<String, String?>? {
        if (i == null) return null
        val callId = i.getStringExtra(NotificationHelper.EXTRA_CALL_ID)
        return when (i.action) {
            NotificationHelper.ACTION_ACCEPT -> {
                NotificationHelper.cancelCall(this)
                mapOf("action" to "answer", "callId" to callId, "convKey" to null)
            }
            NotificationHelper.ACTION_SHOW_CALL -> mapOf("action" to "show_call", "callId" to callId, "convKey" to null)
            NotificationHelper.ACTION_OPEN_CONV -> {
                val key = i.getStringExtra(NotificationHelper.EXTRA_CONV_KEY)
                if (key != null) NotificationHelper.dismissConversation(this, key, ArrayList())
                mapOf("action" to "open_conv", "callId" to null, "convKey" to key)
            }
            else -> null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qyriptalk/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "setSession" -> {
                        val uid = call.argument<String>("uid")
                        val username = call.argument<String>("username") ?: ""
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        Session.save(this, uid, username, enabled)
                        Session.savePrefs(
                            this,
                            call.argument<Boolean>("sound") ?: true,
                            call.argument<Boolean>("preview") ?: true,
                            call.argument<Boolean>("speak") ?: false
                        )
                        NotificationHelper.createChannels(this)
                        KeepAliveService.ensureRunning(this)
                        result.success(true)
                    }
                    "clearSession" -> {
                        Session.clear(this)
                        NotificationHelper.clearMessages(this)
                        NotificationHelper.cancelCall(this)
                        KeepAliveService.stop(this)
                        result.success(true)
                    }
                    "setInCall" -> {
                        KeepAliveService.start(this, call.argument<Boolean>("inCall") ?: false)
                        result.success(true)
                    }
                    "cancelCallNotification" -> {
                        NotificationHelper.cancelCall(this)
                        result.success(true)
                    }
                    "dismissConversation" -> {
                        val key = call.argument<String>("key")
                        if (key != null) NotificationHelper.dismissConversation(this, key, ArrayList())
                        result.success(true)
                    }
                    "takeLaunchAction" -> {
                        val p = pendingLaunch
                        pendingLaunch = null
                        result.success(p)
                    }
                    "canUseFullScreen" -> result.success(NotificationHelper.canUseFullScreen(this))
                    "openFullScreenSettings" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                                    .setData(Uri.parse("package:$packageName"))
                            )
                        }
                        result.success(true)
                    }
                    "isIgnoringBattery" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBattery" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                    .setData(Uri.parse("package:$packageName"))
                            )
                        } catch (e: Exception) {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                        }
                        result.success(true)
                    }
                    "openNotificationSettings" -> {
                        val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        startActivity(i)
                        result.success(true)
                    }
                    "notificationsEnabled" -> {
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        result.success(nm.areNotificationsEnabled())
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("native", e.message, null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
