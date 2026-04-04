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
