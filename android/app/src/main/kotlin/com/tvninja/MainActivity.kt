package io.github.giuig.tvninja

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val PIP_CHANNEL = "io.github.giuig.tvninja/pip"
    private val PIP_EVENTS_CHANNEL = "io.github.giuig.tvninja/pip_events"
    private var isFullscreenVideoMode = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        TvNinjaPlugin.registerWith(flutterEngine.dartExecutor.binaryMessenger, this)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPictureInPicture" -> {
                    val success = enterPipMode()
                    result.success(success)
                }
                "isPipSupported" -> {
                    result.success(isPipSupported())
                }
                "setFullscreenVideoMode" -> {
                    isFullscreenVideoMode = call.arguments as Boolean
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_EVENTS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    TvNinjaPlugin.setPipEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    TvNinjaPlugin.setPipEventSink(null)
                }
            }
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        TvNinjaPlugin.stopService(this)
        super.onDestroy()
    }

    /**
     * Auto-enters picture-in-picture whenever the user leaves the app during
     * eligible playback — Home, the recents key, or switching apps.
     *
     * KEPT DELIBERATELY (owner decision, 2026-09-17). The consequence is known
     * and accepted: because a PiP window lives in its own pinned task, the app
     * keeps playing after the user removes it from Recents — verified on the
     * emulator that even the launcher's "clear all" leaves it playing, with the
     * process alive and ExoPlayer still decoding. Only a force-stop clears it.
     * The owner reported this ("my phone says the app is still active"), was
     * shown the cause, and chose to keep the behaviour as it is.
     *
     * So this is NOT an open bug. Do not "fix" it by adding a foreground service
     * for video just to get Service.onTaskRemoved (it may never fire for a
     * pinned stack, and it costs a permanent notification), and do not make PiP
     * conditional here without asking — making PiP explicit rather than
     * automatic was offered and declined for now. The analysis, including the
     * options that were ruled out and why, is in the ninjapp-claude-rules repo
     * under tvninja/pip-task-removal/RESEARCH.md.
     *
     * The one part of the report that WAS a defect is fixed separately: the
     * screen-on wakelock is no longer held while in PiP. See
     * player_page.dart's _syncWakelock.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (isPipSupported() && isFullscreenVideoMode) {
            enterPipMode()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureMode, newConfig)
        TvNinjaPlugin.onPipModeChanged(isInPictureMode)
    }

    private fun isPipSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
    }

    private fun enterPipMode(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val aspectRatio = Rational(16, 9)
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(aspectRatio)
                .build()
            return enterPictureInPictureMode(params)
        }
        return false
    }
}
