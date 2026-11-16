package io.github.giuig.tvninja

import android.app.ForegroundServiceStartNotAllowedException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class TvNinjaPlugin private constructor(
    private val context: Context
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private var eventSink: EventChannel.EventSink? = null
    private var pipEventSink: EventChannel.EventSink? = null
    private var isInPipMode = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startBackground" -> {
                val title = call.argument<String>("title") ?: "TV Ninja"
                val logo = call.argument<String>("logo")
                try {
                    startBackgroundService(title, logo)
                    result.success(true)
                } catch (e: IllegalStateException) {
                    // From API 31 the system refuses to start a foreground service
                    // from the background (ForegroundServiceStartNotAllowedException,
                    // an IllegalStateException). Dart treats that as "no service".
                    if (isForegroundStartNotAllowed(e)) {
                        Log.w(TAG, "Foreground service start refused: ${e.message}")
                        result.error("FGS_NOT_ALLOWED", e.message, null)
                    } else {
                        throw e
                    }
                }
            }
            "isInteractive" -> {
                // False while the screen is off (a locked phone), true otherwise.
                val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(power.isInteractive)
            }
            "updatePlaybackState" -> {
                val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                val isBuffering = call.argument<Boolean>("isBuffering") ?: false
                val title = call.argument<String>("title") ?: "TV Ninja"
                val logo = call.argument<String>("logo")
                updatePlaybackState(isPlaying, isBuffering, title, logo)
                result.success(true)
            }
            "stopBackground" -> {
                stopBackgroundService()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun startBackgroundService(title: String, logo: String?) {
        val intent = Intent(context, TvNinjaBackgroundService::class.java).apply {
            action = TvNinjaBackgroundService.ACTION_START
            putExtra(TvNinjaBackgroundService.EXTRA_TITLE, title)
            putExtra(TvNinjaBackgroundService.EXTRA_LOGO, logo)
        }
        // Started only, never bound: the service's onBind returns null, and a
        // binding that nobody unbinds keeps the service (and its media session)
        // alive after it asks to stop.
        //
        // Counted before the call, so a stop that follows right away already sees
        // the start as pending and waits for it (see [requestStop]).
        pendingStarts++
        if (pendingStarts == 1) pendingSince = SystemClock.elapsedRealtime()
        // A stop that was waiting on an earlier start is cancelled by this newer
        // start (the user wants playback again), but only if this start happens.
        val deferredStop = stopAfterStart
        stopAfterStart = false
        try {
            context.startForegroundService(intent)
        } catch (e: RuntimeException) {
            // Nothing was started, so nothing will report back, and the stop that
            // was waiting must still happen.
            pendingStarts--
            stopAfterStart = deferredStop
            if (pendingStarts == 0 && stopAfterStart) {
                // Not reachable while the earlier start is still counted (a
                // deferred stop implies one is pending), but if the counter was
                // ever reset nobody else would honour it.
                stopAfterStart = false
                context.stopService(Intent(context, TvNinjaBackgroundService::class.java))
            }
            throw e
        }
    }

    private fun updatePlaybackState(isPlaying: Boolean, isBuffering: Boolean, title: String, logo: String?) {
        val intent = Intent(context, TvNinjaBackgroundService::class.java).apply {
            action = "io.github.giuig.tvninja.UPDATE_STATE"
            putExtra("isPlaying", isPlaying)
            putExtra("isBuffering", isBuffering)
            putExtra("title", title)
            putExtra("logo", logo)
        }
        context.startService(intent)
    }

    private fun stopBackgroundService() = requestStop(context)

    companion object {
        private const val TAG = "TvNinjaPlugin"
        private const val CHANNEL_NAME = "io.github.giuig.tvninja/audio"
        private const val NOISY_CHANNEL_NAME = "io.github.giuig.tvninja/noisy_events"

        // A start that has not reported back for this long is treated as lost: the
        // system itself gives up on a foreground start after a few seconds, so a
        // stop must not wait on it any longer.
        private const val PENDING_START_TIMEOUT_MS = 15_000L

        // startForegroundService calls whose service has not yet called
        // startForeground, and a stop that arrived meanwhile. Android crashes the
        // app ("did not then call Service.startForeground()") when the service is
        // stopped before it did, so such a stop waits for the service's own report.
        // Both are touched only on the main thread: the method channel handler and
        // the service's onStartCommand both run there.
        private var pendingStarts = 0
        private var pendingSince = 0L
        private var stopAfterStart = false

        private var instance: TvNinjaPlugin? = null

        private fun isForegroundStartNotAllowed(e: IllegalStateException): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                e is ForegroundServiceStartNotAllowedException

        /**
         * Stops the playback service, or, while a start is still waiting for the
         * service to call startForeground, remembers to stop it the moment it has.
         *
         * stopService rather than a stop command: it never creates a service just to
         * stop it (from the background that would be refused), and the service's
         * onDestroy releases the session, locks and notification.
         */
        fun requestStop(context: Context) {
            if (pendingStarts > 0 &&
                SystemClock.elapsedRealtime() - pendingSince > PENDING_START_TIMEOUT_MS
            ) {
                Log.w(TAG, "A foreground start never reported back, stopping anyway")
                pendingStarts = 0
                stopAfterStart = false
            }
            if (pendingStarts > 0) {
                Log.d(TAG, "Stop requested while a start is pending, deferring it")
                stopAfterStart = true
                return
            }
            context.stopService(Intent(context, TvNinjaBackgroundService::class.java))
        }

        /**
         * Called by the service once an ACTION_START has been handled (its
         * startForeground ran, or was refused). Returns true when a stop was
         * requested while it was pending and nothing newer is pending: the service
         * then stops itself.
         */
        fun onForegroundStarted(): Boolean {
            if (pendingStarts > 0) pendingStarts--
            if (pendingStarts == 0 && stopAfterStart) {
                stopAfterStart = false
                return true
            }
            return false
        }

        fun registerWith(messenger: BinaryMessenger, context: Context) {
            if (instance == null) {
                instance = TvNinjaPlugin(context.applicationContext)
            }

            val methodChannel = MethodChannel(messenger, CHANNEL_NAME)
            methodChannel.setMethodCallHandler(instance)

            val eventChannel = EventChannel(messenger, "${CHANNEL_NAME}_events")
            eventChannel.setStreamHandler(instance)

            EventChannel(messenger, NOISY_CHANNEL_NAME)
                .setStreamHandler(NoisyStreamHandler(context.applicationContext))
        }

        fun getInstance(): TvNinjaPlugin? = instance

        fun stopService(context: Context) {
            if (instance != null) requestStop(context)
            instance = null
        }

        fun onPlaybackEvent(data: Map<String, Any?>) {
            instance?.eventSink?.success(data)
        }

        fun onPipModeChanged(isInPip: Boolean) {
            instance?.let {
                it.isInPipMode = isInPip
                it.pipEventSink?.success(isInPip)
            }
        }

        fun setPipEventSink(sink: EventChannel.EventSink?) {
            instance?.pipEventSink = sink
        }
    }
}

/**
 * Forwards Android's ACTION_AUDIO_BECOMING_NOISY (headphones about to
 * disconnect, output falling back to the speaker) to Dart as "becomingNoisy",
 * where the player page pauses whichever mode is playing.
 *
 * The receiver is registered only while Dart listens, so it lives exactly as
 * long as a player page does.
 *
 * Debug builds also accept [DEBUG_ACTION], because the system broadcast is
 * protected and cannot be sent from adb:
 * `adb shell am broadcast -a io.github.giuig.tvninja.DEBUG_BECOMING_NOISY`.
 */
private class NoisyStreamHandler(private val context: Context) : EventChannel.StreamHandler {
    private var receiver: BroadcastReceiver? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        unregister()
        val sink = events ?: return
        // Debuggable = a debug build; release APKs never carry this flag.
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (debuggable) filter.addAction(DEBUG_ACTION)
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                Log.d(TAG, "Audio becoming noisy (${intent?.action}) - asking Dart to pause")
                sink.success("becomingNoisy")
            }
        }
        // Exported only in debug, for the adb trigger; system broadcasts still
        // reach a not-exported receiver.
        val flags = if (debuggable) ContextCompat.RECEIVER_EXPORTED
            else ContextCompat.RECEIVER_NOT_EXPORTED
        ContextCompat.registerReceiver(context, r, filter, flags)
        receiver = r
    }

    override fun onCancel(arguments: Any?) = unregister()

    private fun unregister() {
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Already unregistered.
            }
        }
        receiver = null
    }

    companion object {
        private const val TAG = "TvNinjaNoisy"
        const val DEBUG_ACTION = "io.github.giuig.tvninja.DEBUG_BECOMING_NOISY"
    }
}
