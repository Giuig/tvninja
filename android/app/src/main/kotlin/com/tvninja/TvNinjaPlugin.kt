package io.github.giuig.tvninja

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.ApplicationInfo
import android.media.AudioManager
import android.os.IBinder
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
    private var backgroundService: TvNinjaBackgroundService? = null
    private var isBound = false
    private var isInPipMode = false

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            // Service started, we don't need to bind for now
            isBound = true
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            backgroundService = null
            isBound = false
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startBackground" -> {
                val title = call.argument<String>("title") ?: "TV Ninja"
                val logo = call.argument<String>("logo")
                startBackgroundService(title, logo)
                result.success(true)
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
        context.startForegroundService(intent)
        
        // Also bind to keep reference
        if (!isBound) {
            context.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
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

    private fun stopBackgroundService() {
        val intent = Intent(context, TvNinjaBackgroundService::class.java).apply {
            action = TvNinjaBackgroundService.ACTION_STOP
        }
        context.startService(intent)
        
        if (isBound) {
            try {
                context.unbindService(serviceConnection)
            } catch (e: Exception) {
                // Ignore if not bound
            }
            isBound = false
        }
    }

    companion object {
        private const val CHANNEL_NAME = "io.github.giuig.tvninja/audio"
        private const val NOISY_CHANNEL_NAME = "io.github.giuig.tvninja/noisy_events"

        private var instance: TvNinjaPlugin? = null

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
            instance?.let {
                val intent = Intent(context, TvNinjaBackgroundService::class.java)
                context.stopService(intent)
            }
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
