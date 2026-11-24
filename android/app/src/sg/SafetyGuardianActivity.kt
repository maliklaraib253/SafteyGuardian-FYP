package com.example.safety_guardian

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.view.WindowManager
import android.provider.CallLog
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Launcher activity for SafetyGuardian.
 *
 * Lives in android/app/src/sg (added as an extra source dir in app/build.gradle.kts)
 * and replaces MainActivity in AndroidManifest.xml. It exposes two channels:
 *  - com.safetyguardian/app_control : bringToFront (used by Distress Detection)
 *  - com.safetyguardian/call_guard  : endCall / canEndCall (auto-reject during SOS),
 *                                     setBeepMuted (silent voice-distress monitoring)
 *  - com.safetyguardian/sms         : sendSms (SOS texts, dual-SIM aware, reports
 *                                     whether the network accepted the message)
 */
class SafetyGuardianActivity : FlutterActivity() {

    companion object {
        private const val ENGINE_ID = "safety_guardian_engine"
    }

    /**
     * One Flutter engine for the whole app process, kept in a cache.
     * When the user closes the app (back button or swipes it from Recents)
     * only this screen goes away - the engine, and with it Distress Detection,
     * keeps running as long as the foreground service keeps the process alive.
     * Opening the app again re-attaches to the same running engine.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        // The FlutterEngine constructor registers all plugins automatically.
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "com.safetyguardian/app_control").setMethodCallHandler { call, result ->
            when (call.method) {
                "bringToFront" -> {
                    bringToFront()
                    result.success(true)
                }
                "showDistressAlert" -> {
                    showDistressAlert(
                        call.argument<String>("title") ?: "Are you safe?",
                        call.argument<String>("text") ?: ""
                    )
                    result.success(true)
                }
                "cancelDistressAlert" -> {
                    cancelDistressAlert()
                    result.success(true)
                }
                "setShowOnLockScreen" -> {
                    setShowOnLockScreen(call.argument<Boolean>("on") ?: false)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "com.safetyguardian/call_guard").setMethodCallHandler { call, result ->
            when (call.method) {
                "canEndCall" -> result.success(canEndCall())
                "endCall" -> result.success(endCall())
                "setBeepMuted" -> {
                    setBeepMuted(call.argument<Boolean>("muted") ?: false)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "com.safetyguardian/sms").setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    val message = call.argument<String>("message") ?: ""
                    sendSms(phone, message) { ok, error ->
                        result.success(mapOf("ok" to ok, "error" to error))
                    }
                }
                "call" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    result.success(placeCall(phone))
                }
                "isInCall" -> result.success(isInCall())
                "lastCallDuration" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    val since = (call.argument<Number>("since") ?: 0).toLong()
                    result.success(lastOutgoingCallDuration(phone, since))
                }
                else -> result.notImplemented()
            }
        }
    }

    private var smsRequestCode = 1000

    /**
     * Sends an SMS automatically, with no user interaction.
     * Tries the default SMS SIM first, then every other active SIM, so it
     * still works when the phone is set to "Ask every time" or one SIM has
     * no balance/signal. [done] gets (sent, lastError).
     */
    private fun sendSms(phone: String, message: String, done: (Boolean, String?) -> Unit) {
        if (phone.isBlank() || message.isBlank()) {
            done(false, "empty phone or message"); return
        }
        if (checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            done(false, "SMS permission not granted"); return
        }
        val managers = try {
            smsManagersToTry()
        } catch (e: Exception) {
            done(false, "no SIM available: ${e.message}"); return
        }
        if (managers.isEmpty()) {
            done(false, "no SIM available"); return
        }

        fun attempt(index: Int, lastError: String?) {
            if (index >= managers.size) {
                done(false, lastError); return
            }
            sendWith(managers[index], phone, message) { ok, error ->
                if (ok) done(true, null) else attempt(index + 1, error)
            }
        }
        attempt(0, null)
    }

    private fun sendWith(
        manager: SmsManager,
        phone: String,
        message: String,
        done: (Boolean, String?) -> Unit
    ) {
        val action = "com.safetyguardian.SMS_SENT_" + (smsRequestCode++)
        val handler = Handler(Looper.getMainLooper())
        var finished = false
        lateinit var receiver: BroadcastReceiver

        fun finish(ok: Boolean, error: String?) {
            if (finished) return
            finished = true
            Log.i("SG_SMS", "SMS to $phone -> ok=$ok error=$error")
            try { applicationContext.unregisterReceiver(receiver) } catch (_: Exception) {}
            done(ok, error)
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (resultCode) {
                    Activity.RESULT_OK -> finish(true, null)
                    SmsManager.RESULT_ERROR_NO_SERVICE -> finish(false, "no mobile signal")
                    SmsManager.RESULT_ERROR_RADIO_OFF -> finish(false, "airplane mode / radio off")
                    SmsManager.RESULT_ERROR_NULL_PDU -> finish(false, "message could not be encoded")
                    else -> finish(false, "send failed (code $resultCode) - check SMS balance")
                }
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            applicationContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            applicationContext.registerReceiver(receiver, filter)
        }

        val flags = PendingIntent.FLAG_ONE_SHOT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val sentIntent = PendingIntent.getBroadcast(
            applicationContext, smsRequestCode, Intent(action).setPackage(packageName), flags
        )

        try {
            val parts = manager.divideMessage(message)
            if (parts.size > 1) {
                val sent = ArrayList<PendingIntent?>()
                sent.add(sentIntent)
                for (i in 1 until parts.size) sent.add(null)
                manager.sendMultipartTextMessage(phone, null, parts, sent, null)
            } else {
                manager.sendTextMessage(phone, null, message, sentIntent, null)
            }
        } catch (e: Exception) {
            Log.e("SG_SMS", "sendTextMessage threw", e)
            finish(false, "send error: ${e.javaClass.simpleName}: ${e.message}")
            return
        }

        // Some ROMs never report back; assume it went out after 20 s.
        handler.postDelayed({
            Log.w("SG_SMS", "No sent-report for $phone after 20 s (ROM did not confirm)")
            finish(true, null)
        }, 20000)
    }

    /**
     * Places a phone call straight away through the SIM Android would use
     * (default calling SIM, or the first SIM that can make calls when the
     * phone is set to "Ask every time"). Returns null on success or an error.
     */
    @Suppress("MissingPermission")
    private fun placeCall(phone: String): String? {
        if (phone.isBlank()) return "empty phone number"
        if (checkSelfPermission(Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
            return "call permission not granted"
        }
        val uri = Uri.fromParts("tel", phone, null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return try {
                val telecom = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                var account: PhoneAccountHandle? = telecom.getDefaultOutgoingPhoneAccount("tel")
                if (account == null &&
                    checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
                ) {
                    account = telecom.callCapablePhoneAccounts.firstOrNull()
                }
                val extras = Bundle()
                if (account != null) {
                    extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account)
                }
                telecom.placeCall(uri, extras)
                null
            } catch (e: Exception) {
                callWithIntent(uri)
            }
        }
        return callWithIntent(uri)
    }

    /** True while any call (ringing, dialling or talking) is in progress. */
    @Suppress("MissingPermission")
    private fun isInCall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        return try {
            (getSystemService(Context.TELECOM_SERVICE) as TelecomManager).isInCall
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Talk time in seconds of the latest outgoing call to [phone] placed after
     * [since] (epoch ms). 0 = not answered, -1 = unknown (no call-log access or
     * no matching entry yet).
     */
    private fun lastOutgoingCallDuration(phone: String, since: Long): Int {
        if (checkSelfPermission(Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) {
            return -1
        }
        val wanted = phone.filter { it.isDigit() }.takeLast(10)
        if (wanted.isEmpty()) return -1
        return try {
            contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.DURATION),
                "${CallLog.Calls.TYPE} = ? AND ${CallLog.Calls.DATE} >= ?",
                arrayOf(CallLog.Calls.OUTGOING_TYPE.toString(), (since - 5000).toString()),
                "${CallLog.Calls.DATE} DESC"
            )?.use { c ->
                while (c.moveToNext()) {
                    val number = (c.getString(0) ?: "").filter { it.isDigit() }.takeLast(10)
                    if (number == wanted) return@use c.getInt(1)
                }
                -1
            } ?: -1
        } catch (e: Exception) {
            -1
        }
    }

    private fun callWithIntent(uri: Uri): String? {
        return try {
            applicationContext.startActivity(Intent(Intent.ACTION_CALL, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            null
        } catch (e: Exception) {
            "call failed: ${e.message}"
        }
    }

    /** Default SMS SIM first, then every other active SIM. */
    @Suppress("DEPRECATION")
    private fun smsManagersToTry(): List<SmsManager> {
        val ids = LinkedHashSet<Int>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val def = SubscriptionManager.getDefaultSmsSubscriptionId()
            if (def != SubscriptionManager.INVALID_SUBSCRIPTION_ID) ids.add(def)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1 &&
            checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
        ) {
            try {
                getSystemService(SubscriptionManager::class.java)
                    ?.activeSubscriptionInfoList
                    ?.forEach { ids.add(it.subscriptionId) }
            } catch (_: SecurityException) {}
        }
        if (ids.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) {
            return listOf(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    getSystemService(SmsManager::class.java)
                else SmsManager.getDefault()
            )
        }
        return ids.map { id ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                getSystemService(SmsManager::class.java).createForSubscriptionId(id)
            else SmsManager.getSmsManagerForSubscriptionId(id)
        }
    }

    private fun bringToFront() {
        val intent = Intent(applicationContext, SafetyGuardianActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        try {
            applicationContext.startActivity(intent)
        } catch (e: Exception) {
            // Android 10+ may block opening an activity from the background;
            // the full-screen alert notification covers that case.
            Log.w("SG_ALERT", "bringToFront blocked: ${e.message}")
        }
    }

    private val alertChannelId = "distress_alert_channel"
    private val alertNotificationId = 4711

    /** Keeps the CPU awake during the "Are you safe?" countdown, so the
     *  2-minute timer keeps running with the screen off. */
    private var alertWakeLock: PowerManager.WakeLock? = null

    private fun holdAlertWakeLock() {
        try {
            if (alertWakeLock?.isHeld == true) return
            val pm = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            alertWakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SafetyGuardian:distressAlert"
            ).apply {
                setReferenceCounted(false)
                acquire(4 * 60 * 1000L) // safety timeout: alert is 2 min
            }
        } catch (e: Exception) {
            Log.w("SG_ALERT", "wake lock failed: ${e.message}")
        }
    }

    private fun releaseAlertWakeLock() {
        try {
            if (alertWakeLock?.isHeld == true) alertWakeLock?.release()
        } catch (_: Exception) {}
        alertWakeLock = null
    }

    /**
     * High-priority "Are you safe?" notification with a full-screen intent:
     * on a locked or idle phone Android opens the app over the lock screen
     * (like an incoming call or alarm); otherwise it shows as a heads-up
     * banner. Opening an activity directly from the background is blocked
     * on Android 10+, so this is what makes the alert visible.
     */
    @Suppress("DEPRECATION")
    private fun showDistressAlert(title: String, text: String) {
        holdAlertWakeLock()
        val ctx = applicationContext
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(alertChannelId) == null
        ) {
            val channel = NotificationChannel(
                alertChannelId,
                "Distress alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "\"Are you safe?\" countdown after distress is detected"
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(channel)
        }
        val open = Intent(ctx, SafetyGuardianActivity::class.java).addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        )
        val pending = PendingIntent.getActivity(
            ctx,
            alertNotificationId,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, alertChannelId)
        } else {
            Notification.Builder(ctx).setPriority(Notification.PRIORITY_MAX)
        }
        builder
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setContentIntent(pending)
            .setFullScreenIntent(pending, true)
        try {
            nm.notify(alertNotificationId, builder.build())
        } catch (e: Exception) {
            Log.w("SG_ALERT", "alert notification failed: ${e.message}")
        }
    }

    private fun cancelDistressAlert() {
        releaseAlertWakeLock()
        try {
            val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(alertNotificationId)
        } catch (_: Exception) {}
    }

    /** Lets the alert appear over the lock screen and switch the screen on. */
    @Suppress("DEPRECATION")
    private fun setShowOnLockScreen(on: Boolean) {
        runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    setShowWhenLocked(on)
                    setTurnScreenOn(on)
                } else {
                    val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                    if (on) window.addFlags(flags) else window.clearFlags(flags)
                }
            } catch (_: Exception) {}
        }
    }

    private var beepMuted = false
    private var musicMutedByUs = false
    private val beepHandler = Handler(Looper.getMainLooper())

    /** Volumes saved before muting, restored when monitoring stops. */
    private val savedVolumes = HashMap<Int, Int>()

    private fun beepStreams(): IntArray {
        // Not STREAM_NOTIFICATION: on many phones it is tied to the ringtone,
        // and muting it would also silence incoming calls.
        val list = mutableListOf(AudioManager.STREAM_SYSTEM)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            list.add(AudioManager.STREAM_ACCESSIBILITY)
        }
        return list.toIntArray()
    }

    /** Mute + volume 0: some phones ignore one of the two. */
    private fun silence(audio: AudioManager, stream: Int) {
        try {
            if (!savedVolumes.containsKey(stream)) {
                savedVolumes[stream] = audio.getStreamVolume(stream)
            }
            audio.adjustStreamVolume(stream, AudioManager.ADJUST_MUTE, 0)
        } catch (e: Exception) {
            Log.w("SG_BEEP", "mute $stream failed: ${e.message}")
        }
        try {
            audio.setStreamVolume(stream, 0, 0)
        } catch (e: Exception) {
            Log.w("SG_BEEP", "volume 0 on $stream failed: ${e.message}")
        }
    }

    private fun restore(audio: AudioManager, stream: Int) {
        try {
            audio.adjustStreamVolume(stream, AudioManager.ADJUST_UNMUTE, 0)
        } catch (_: Exception) {}
        val v = savedVolumes.remove(stream) ?: return
        try {
            audio.setStreamVolume(stream, v, 0)
        } catch (e: Exception) {
            Log.w("SG_BEEP", "restore $stream failed: ${e.message}")
        }
    }

    /** While muted: if the user starts music or a video, give the sound back.
     *  The recogniser's own beep also counts as "music playing" for a moment,
     *  so music must play for 3 s in a row (6 checks, 0.5 s apart) before
     *  the sound is given back; a beep (< 1 s) never gets that far. */
    private var musicActiveChecks = 0
    private val musicWatcher = object : Runnable {
        override fun run() {
            if (!beepMuted) return
            try {
                val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                if (audio.isMusicActive) musicActiveChecks++ else musicActiveChecks = 0
                if (musicMutedByUs && musicActiveChecks >= 6) {
                    Log.i("SG_BEEP", "user is playing media: music sound back on")
                    restore(audio, AudioManager.STREAM_MUSIC)
                    musicMutedByUs = false
                }
            } catch (_: Exception) {}
            beepHandler.postDelayed(this, 500)
        }
    }

    /**
     * Silences the start/stop "ding/tik" of Android's SpeechRecognizer for
     * the whole time voice-distress monitoring is on: system and
     * accessibility sounds, plus music while no media is playing (given
     * back when the user plays something). Calls (ring) and alarms are never
     * touched. All volumes are restored when monitoring stops.
     */
    private fun setBeepMuted(muted: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (muted) {
            if (!beepMuted) {
                beepMuted = true
                musicActiveChecks = 0
                for (st in beepStreams()) silence(audio, st)
                beepHandler.removeCallbacks(musicWatcher)
                beepHandler.postDelayed(musicWatcher, 500)
            }
            // Before every listening session: mute music again once the
            // user's media has stopped.
            if (!musicMutedByUs && musicActiveChecks == 0 && !audio.isMusicActive) {
                silence(audio, AudioManager.STREAM_MUSIC)
                musicMutedByUs = true
            }
            Log.i(
                "SG_BEEP",
                "session muted: system=${audio.getStreamVolume(AudioManager.STREAM_SYSTEM)} " +
                    "notif=${audio.getStreamVolume(AudioManager.STREAM_NOTIFICATION)} " +
                    "music=${audio.getStreamVolume(AudioManager.STREAM_MUSIC)} " +
                    "musicActive=${audio.isMusicActive} ringer=${audio.ringerMode}"
            )
        } else {
            beepHandler.removeCallbacks(musicWatcher)
            if (beepMuted) for (st in beepStreams()) restore(audio, st)
            if (musicMutedByUs) restore(audio, AudioManager.STREAM_MUSIC)
            beepMuted = false
            musicMutedByUs = false
            Log.i("SG_BEEP", "monitoring off: sounds restored")
        }
    }

    private fun canEndCall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        return checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) ==
            PackageManager.PERMISSION_GRANTED
    }

    @Suppress("DEPRECATION")
    private fun endCall(): Boolean {
        if (!canEndCall()) return false
        return try {
            val telecom = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            telecom.endCall()
        } catch (e: SecurityException) {
            false
        } catch (e: Exception) {
            false
        }
    }
}
