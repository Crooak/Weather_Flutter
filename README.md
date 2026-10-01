# One UI Weather

A Flutter weather application with a glassmorphism design inspired by Samsung One UI. Supports GPS-based auto-detection and manual city search, hourly and daily forecasts, seasonal animated backgrounds, and dynamic weather effects.

## Features

- **Two location modes** — automatic GPS detection with reverse geocoding, or manual city search powered by Nominatim (OpenStreetMap).
- **Swipe navigation** — swipe left/right to switch between GPS and manual modes.
- **Current conditions** — temperature, feels-like, wind, humidity, pressure, UV index, visibility, sunrise and sunset.
- **Hourly forecast** — 26 hourly slots (−2 to +23 hours from now), auto-centered on the current hour.
- **Daily forecast** — 3-day outlook with separate day and night icons.
- **Weather icons** — dynamic icons for rain, snow, thunder, fog, clouds, and clear skies. Sun and moon variants adapt to time of day.
- **Glassmorphism UI** — frosted glass panels with `BackdropFilter` blur throughout.
- **Seasonal backgrounds** — four hand-drawn vector scenes (spring, summer, autumn, winter) plus an option to disable.
- **Weather effects** — animated sun rays, drifting clouds, falling rain, snow, thunder flashes, and fog bands layered over the seasonal background.
- **Humidity droplet** — custom `CustomPainter` rendering a teardrop with fill proportional to the current humidity.
- **Persistent preferences** — selected background is saved across app restarts via `shared_preferences`.
- **Smart GPS caching** — coordinates are cached for 15 minutes to avoid hammering the GPS module on every refresh.
- **Pull-to-refresh** and **auto-refresh** on app resume (if more than 5 minutes have passed).

## Screenshots

*(Add your screenshots here — light and dark, different seasons and weather conditions.)*

## Tech stack

| Component | Purpose |
|---|---|
| [Flutter](https://flutter.dev) | UI framework |
| [http](https://pub.dev/packages/http) | Network requests |
| [geolocator](https://pub.dev/packages/geolocator) | Device location |
| [shared_preferences](https://pub.dev/packages/shared_preferences) | Persisting user preferences |
| [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons) | Generating launcher icons (dev dependency) |

## Data sources

- **Weather:** [wttr.in](https://wttr.in) — free, no API key, JSON format (`?format=j1`), Russian descriptions (`&lang=ru`).
- **Forward geocoding (city search):** [Nominatim](https://nominatim.openstreetmap.org) — OpenStreetMap's free geocoder, structured address details.
- **Reverse geocoding (GPS → city name):** Nominatim reverse endpoint.

> **Note:** `open-meteo.com` is unreachable from some regions (including Russia) without a VPN, which is why `wttr.in` and Nominatim were chosen instead.

## Project structure

```
lib/
├── main.dart                      # App entry point
├── constants/
│   └── app_colors.dart            # Gradient and color constants
├── screens/
│   └── weather_screen.dart        # Main screen — all UI and logic
└── services/
    └── location_service.dart      # GPS wrapper with status reporting
```

### Key classes in `weather_screen.dart`

| Class | Responsibility |
|---|---|
| `WeatherScreen` | Screen widget |
| `_WeatherScreenState` | State — all business logic, request lifecycle, GPS caching, swipe handling, season selection |
| `_SeasonalBackgroundPainter` | Draws layered hills and animated seasonal particles |
| `_WeatherEffectsPainter` | Draws weather-driven overlays (sun, clouds, rain, snow, thunder, fog) |
| `_DropletPainter` | Humidity droplet with proportional fill |
| `_WeatherEffect` (enum) | Sun / partly / cloudy / overcast / rain / snow / thunder / fog / none |

## Getting started

### Prerequisites

- Flutter SDK 3.10 or newer (uses null-aware collection elements `?x`)
- Android SDK or Xcode for running on a device/emulator

### Setup

```bash
git clone <your-repo-url>
cd <project-folder>
flutter pub get
```

Make sure your `pubspec.yaml` includes:

```yaml
dependencies:
  flutter:
    sdk: flutter
  http: ^1.1.0
  geolocator: ^10.1.0
  shared_preferences: ^2.2.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_launcher_icons: ^0.13.1
```

### Platform permissions

**Android** — add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

**iOS** — add to `ios/Runner/Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Used to show weather for your current location</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Used to show weather for your current location</string>
```

### Running

```bash
flutter run
```

## Launcher icons

The project uses `flutter_launcher_icons` to generate platform-specific icons from a single source image.

1. Place a **1024×1024 PNG** at the project root (e.g. `app_icon.png`). SVG files are **not** supported — convert them to PNG first.
2. Add the config to `pubspec.yaml`:

   ```yaml
   flutter_launcher_icons:
     android: true
     ios: true
     image_path: "app_icon.png"
     remove_alpha_ios: true
   ```

3. Run:

   ```bash
   flutter pub run flutter_launcher_icons
   ```

4. **Uninstall** the app from the device and reinstall it — otherwise the Android launcher may keep showing the old cached icon.

## Architecture notes

### Request lifecycle and cancellation

Every weather request carries a numeric `_weatherRequestId`. Before writing to state, it checks the token is still current. This prevents stale responses from overwriting fresh data when the user switches modes rapidly. The same pattern is used for geocoding with `_geoRequestId`.

### GPS caching

- Coordinates are cached in `_lastGpsLat`, `_lastGpsLon`, and `_lastGpsTime`.
- Reverse-geocoded city name is cached in `_lastGpsCity`.
- Cache TTL is 15 minutes (`_gpsCacheTtl`).
- Pull-to-refresh and app-resume use the cached coordinates and do **not** spin up the GPS module again.

### Background layers

The background is a `Stack` of three layers, all inside a single `ShaderMask` that fades them out toward the bottom:

1. Base gradient (always visible).
2. Seasonal vector scene (hills + particles).
3. Weather-driven effect overlay.

Both animated layers share one `AnimationController` (`_particleController`) so their motion stays in sync.

## Configuration knobs

| Constant | Location | Default | Meaning |
|---|---|---|---|
| `_autoRefreshThreshold` | `_WeatherScreenState` | 5 min | Minimum time before app resume triggers refresh |
| `_gpsCacheTtl` | `_WeatherScreenState` | 15 min | Coordinate cache lifetime |
| `_hoursBack` / `_hoursForward` | `_WeatherScreenState` | 2 / 23 | Hourly forecast range |
| `_prefsKeySeason` | `_WeatherScreenState` | `'season_index'` | Shared preferences key |

## Adding a translation

Open `_translateToRussian` in `weather_screen.dart` and add a new entry to the `map` literal:

```dart
'patchy rain nearby': 'Местами дождь',
```

The same map is applied both to `lang_ru` and `weatherDesc` fields, because `wttr.in` sometimes returns English text in either.

## Adding a season background

1. Add a case to `_SeasonalBackgroundPainter.paint` for a new season index.
2. Add a case to `_paintParticles` for particles.
3. Add a name in `_seasonName` and a preview tap handler in the season picker sheet.

Keep alpha values between `0.18` and `0.34` to preserve the soft, non-intrusive look.

## License

*(Add your license — MIT, Apache 2.0, etc.)*

## Acknowledgements

- Weather data by [wttr.in](https://wttr.in)
- Geocoding by [Nominatim](https://nominatim.openstreetmap.org) / OpenStreetMap contributors
- Icons by [Material Icons](https://fonts.google.com/icons)
