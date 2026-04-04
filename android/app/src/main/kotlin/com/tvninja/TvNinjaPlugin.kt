package io.github.giuig.tvninja

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
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

        private var instance: TvNinjaPlugin? = null

        fun registerWith(messenger: BinaryMessenger, context: Context) {
            if (instance == null) {
                instance = TvNinjaPlugin(context.applicationContext)
            }

            val methodChannel = MethodChannel(messenger, CHANNEL_NAME)
            methodChannel.setMethodCallHandler(instance)

            val eventChannel = EventChannel(messenger, "${CHANNEL_NAME}_events")
            eventChannel.setStreamHandler(instance)
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
