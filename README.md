# tvninja

IPTV / M3U8 player built with Flutter. Watch live TV channels on Android and in the browser with a persistent mini-player experience.


## Features

- **M3U8 Playlist Support** — load and play IPTV streams from M3U8 playlists
- **Xtream Codes Support** — login with Xtream credentials for Live, VOD, and Series
- **IPTV.org Integration** — browse country-based playlists (60+ countries)
- **Favorites** — save channels for quick access from the home screen
- **Search** — find channels quickly by name
- **Group Filtering** — filter channels by category or group
- **Background Audio** — keep listening when the app is in the background (Android)
- **Audio Only Mode** — play audio only to save battery and data (Android)
- **Picture-in-Picture** — auto-PiP when leaving the fullscreen player (Android)
- **Persistent Mini-Player** — navigate the app while watching, tap to expand
- **Web Support** — watch streams in any browser with CORS proxy fallback
- **Material You** — dynamic color theming, light and dark mode
- **Google-Free** — no Google Play Services required, fully FOSS

## Try it Online

**[Launch tvninja](https://giuig.github.io/tvninja/)**

> Some streams may not work in the browser due to CORS restrictions.


## Download

Get the latest APK from the [Releases page](https://github.com/Giuig/tvninja/releases/latest).

| APK | Notes |
|---|---|
| `tvninja-X.X.X.apk` | Universal — works on any device |
| `tvninja-X.X.X-arm64-v8a.apk` | Most modern Android phones |
| `tvninja-X.X.X-armeabi-v7a.apk` | Older 32-bit devices |
| `tvninja-X.X.X-x86_64.apk` | Emulators |

### Install via Obtainium

Add `https://github.com/Giuig/tvninja` in [Obtainium](https://github.com/ImranR98/Obtainium) to receive automatic updates. Use the APK filter `tvninja-\d` to select the universal build.


## Support

I make FOSS apps in my free time, a coffee would help me keep them going! ☕

[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/giuig)

## Build

```bash
# Prerequisites: Flutter SDK 3.41.5+
flutter pub get
flutter build apk --release
flutter build web --base-href=/tvninja/ --release
```

## Part of the ninja apps family

| App | Description |
|---|---|
| [auraninja](https://github.com/Giuig/auraninja) | Ambient sound mixer and focus app |
| [decisioninja](https://github.com/Giuig/decisioninja) | Decision maker with dice, pointer, and binary choices |
| [ninja_material](https://github.com/Giuig/ninja_material) | Shared Flutter library powering all ninja apps |

## License

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](./LICENSE)

This project is licensed under the [GNU General Public License v3.0](./LICENSE).
