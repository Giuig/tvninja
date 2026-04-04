package io.github.giuig.tvninja

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.media.session.MediaButtonReceiver
import java.net.URL

class TvNinjaBackgroundService : Service(), AudioManager.OnAudioFocusChangeListener {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var mediaSession: MediaSessionCompat? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var currentTitle: String = "TV Ninja"
    private var currentLogo: String? = null
    private var isPlaying: Boolean = false
    private var isBuffering: Boolean = false
    private var hadAudioFocus: Boolean = false

    companion object {
        const val TAG = "TvNinjaService"
        const val CHANNEL_ID = "tvninja_playback_channel"
        const val NOTIFICATION_ID = 1
        const val ACTION_PLAY = "io.github.giuig.tvninja.ACTION_PLAY"
        const val ACTION_PAUSE = "io.github.giuig.tvninja.ACTION_PAUSE"
        const val ACTION_STOP = "io.github.giuig.tvninja.ACTION_STOP"
        const val ACTION_START = "io.github.giuig.tvninja.ACTION_START"
        const val ACTION_UPDATE_STATE = "io.github.giuig.tvninja.UPDATE_STATE"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_LOGO = "extra_logo"
    }

    override fun onCreate() {
        Log.d(TAG, "onCreate called")
        super.onCreate()
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        createNotificationChannel()
        setupMediaSession()
        Log.d(TAG, "onCreate completed")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: action=${intent?.action}")
        when (intent?.action) {
            ACTION_PLAY -> {
                Log.d(TAG, "ACTION_PLAY received")
                TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "playRequested"))
            }
            ACTION_PAUSE -> {
                Log.d(TAG, "ACTION_PAUSE received")
                TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "pauseRequested"))
            }
            ACTION_STOP -> {
                Log.d(TAG, "ACTION_STOP received")
                TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "stopRequested"))
                stopBackground()
                stopSelf()
            }
            ACTION_START -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "TV Ninja"
                val logo = intent.getStringExtra(EXTRA_LOGO)
                Log.d(TAG, "ACTION_START: title=$title")
                startBackground(title, logo)
            }
            ACTION_UPDATE_STATE -> {
                val isPlaying = intent.getBooleanExtra("isPlaying", false)
                val isBuffering = intent.getBooleanExtra("isBuffering", false)
                val title = intent.getStringExtra("title") ?: currentTitle
                val logo = intent.getStringExtra("logo") ?: currentLogo
                Log.d(TAG, "ACTION_UPDATE_STATE: isPlaying=$isPlaying, isBuffering=$isBuffering, title=$title")
                updatePlaybackState(isPlaying, isBuffering, title, logo)
            }
        }
        return START_STICKY
    }

    override fun onAudioFocusChange(focusChange: Int) {
        Log.d(TAG, "AudioFocus changed: $focusChange")
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                Log.d(TAG, "AudioFocus: LOSS - pausing playback")
                TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "pauseRequested"))
                hadAudioFocus = false
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                Log.d(TAG, "AudioFocus: LOSS_TRANSIENT - pausing playback")
                TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "pauseRequested"))
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                Log.d(TAG, "AudioFocus: LOSS_TRANSIENT_CAN_DUCK - ducking not supported, pausing")
                TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "pauseRequested"))
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                Log.d(TAG, "AudioFocus: GAIN - resuming playback")
                if (hadAudioFocus) {
                    TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "playRequested"))
                }
            }
        }
    }

    private fun requestAudioFocus(): Boolean {
        val result: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()

            audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(audioAttributes)
                .setOnAudioFocusChangeListener(this)
                .build()

            result = audioManager?.requestAudioFocus(audioFocusRequest!!) ?: AudioManager.AUDIOFOCUS_REQUEST_FAILED
        } else {
            @Suppress("DEPRECATION")
            result = audioManager?.requestAudioFocus(
                this,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            ) ?: AudioManager.AUDIOFOCUS_REQUEST_FAILED
        }

        hadAudioFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        Log.d(TAG, "AudioFocus request result: $result, hadAudioFocus: $hadAudioFocus")
        return hadAudioFocus
    }

    private fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let {
                audioManager?.abandonAudioFocusRequest(it)
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager?.abandonAudioFocus(this)
        }
        hadAudioFocus = false
        Log.d(TAG, "AudioFocus abandoned")
    }

    private fun setupMediaSession() {
        mediaSession = MediaSessionCompat(this, "TvNinjaSession").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    Log.d(TAG, "MediaSession onPlay")
                    TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "playRequested"))
                }

                override fun onPause() {
                    Log.d(TAG, "MediaSession onPause")
                    TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "pauseRequested"))
                }

                override fun onStop() {
                    Log.d(TAG, "MediaSession onStop")
                    TvNinjaPlugin.onPlaybackEvent(mapOf("event" to "stopRequested"))
                }
            })
            isActive = true
        }
        Log.d(TAG, "MediaSession setup complete")
    }

    fun updatePlaybackState(isPlaying: Boolean, isBuffering: Boolean, title: String, logo: String?) {
        Log.d(TAG, "updatePlaybackState: isPlaying=$isPlaying, isBuffering=$isBuffering, title=$title")
        this.isPlaying = isPlaying
        this.isBuffering = isBuffering
        this.currentTitle = title
        this.currentLogo = logo

        if (isPlaying) {
            requestAudioFocus()
        } else if (!isBuffering) {
            // Keep audio focus while buffering so another app doesn't resume
            // in the gap between buffering start and playback start.
            abandonAudioFocus()
        }

        val state = when {
            isBuffering -> PlaybackStateCompat.STATE_BUFFERING
            isPlaying   -> PlaybackStateCompat.STATE_PLAYING
            else        -> PlaybackStateCompat.STATE_PAUSED
        }

        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setState(state, 0, 1.0f)
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                    PlaybackStateCompat.ACTION_PAUSE or
                    PlaybackStateCompat.ACTION_STOP
                )
                .build()
        )

        mediaSession?.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "TV Ninja")
                .build()
        )

        val notification = createNotification(title, logo, isPlaying, isBuffering)
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    fun startBackground(title: String, logo: String?) {
        Log.d(TAG, "startBackground called: title=$title")
        acquireWakeLock()
        currentTitle = title
        currentLogo = logo
        Log.d(TAG, "Calling startForeground...")
        startForeground(NOTIFICATION_ID, createNotification(title, logo, false))
        Log.d(TAG, "startForeground called successfully")
    }

    fun stopBackground() {
        Log.d(TAG, "stopBackground called")
        abandonAudioFocus()
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.cancel(NOTIFICATION_ID)
        stopSelf()
    }

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "TvNinja::AudioWakeLock"
            )
        }
        if (!wakeLock!!.isHeld) {
            wakeLock?.acquire()
            Log.d(TAG, "WakeLock acquired")
        }
        // Keep WiFi alive during background playback so Doze mode cannot
        // suspend the network connection and silently drop the stream.
        if (wifiLock == null) {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wifiManager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "TvNinja::WifiLock"
            )
        }
        if (wifiLock?.isHeld == false) {
            wifiLock?.acquire()
            Log.d(TAG, "WifiLock acquired")
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
                Log.d(TAG, "WakeLock released")
            }
        }
        wakeLock = null
        wifiLock?.let {
            if (it.isHeld) {
                it.release()
                Log.d(TAG, "WifiLock released")
            }
        }
        wifiLock = null
    }

    private fun createNotificationChannel() {
        Log.d(TAG, "Creating notification channel")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "TV Ninja Playback",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "IPTV playback controls"
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
        Log.d(TAG, "Notification channel created")
    }

    private fun buildNotification(
        title: String,
        isPlaying: Boolean,
        isBuffering: Boolean,
        bitmap: Bitmap?,
    ): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Three states: loading → show Stop; playing → show Pause; paused → show Play
        val action = when {
            isBuffering -> NotificationCompat.Action(
                android.R.drawable.ic_delete,
                "Stop",
                createActionIntent(ACTION_STOP)
            )
            isPlaying -> NotificationCompat.Action(
                android.R.drawable.ic_media_pause,
                "Pause",
                createActionIntent(ACTION_PAUSE)
            )
            else -> NotificationCompat.Action(
                android.R.drawable.ic_media_play,
                "Play",
                createActionIntent(ACTION_PLAY)
            )
        }

        val statusText = when {
            isBuffering -> "Loading…"
            isPlaying   -> "Now Playing"
            else        -> "Paused"
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentIntent)
            .addAction(action)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0)
            )
            .setOnlyAlertOnce(true)

        if (isBuffering) {
            builder.setProgress(0, 0, true) // indeterminate spinner
        }

        if (bitmap != null) {
            builder.setLargeIcon(bitmap)
        }

        return builder.build()
    }

    private fun createNotification(title: String, logoUrl: String?, isPlaying: Boolean, isBuffering: Boolean = false): Notification {
        Log.d(TAG, "Creating notification: title=$title, isPlaying=$isPlaying, isBuffering=$isBuffering")

        if (!logoUrl.isNullOrEmpty()) {
            Thread {
                try {
                    val url = URL(logoUrl)
                    val connection = url.openConnection()
                    connection.connectTimeout = 5000
                    connection.readTimeout = 5000
                    val bitmap = BitmapFactory.decodeStream(connection.getInputStream())
                    if (bitmap != null) {
                        val notification = buildNotification(title, this.isPlaying, this.isBuffering, bitmap)
                        val notificationManager = getSystemService(NotificationManager::class.java)
                        notificationManager.notify(NOTIFICATION_ID, notification)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error loading logo: ${e.message}")
                }
            }.start()
        }

        return buildNotification(title, isPlaying, isBuffering, null)
    }

    private fun createActionIntent(action: String): PendingIntent {
        val intent = Intent(this, TvNinjaBackgroundService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(
            this,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy called")
        stopForeground(STOP_FOREGROUND_REMOVE)
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.cancel(NOTIFICATION_ID)
        abandonAudioFocus()
        releaseWakeLock()
        mediaSession?.release()
        super.onDestroy()
    }
}
