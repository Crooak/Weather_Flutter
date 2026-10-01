import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/app_colors.dart';
import '../services/location_service.dart';

class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final LocationService _locationService = LocationService();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _hourlyScrollController = ScrollController();

  final LayerLink _searchFieldLink = LayerLink();
  OverlayEntry? _suggestionsOverlayEntry;

  late final AnimationController _particleController;

  String _city = "Моя локация";
  String _temp = "--";
  String _condition = "Загрузка...";
  String _wind = "--";
  String _humidity = "--";
  String _feelsLike = "--";
  String _pressure = "--";
  String _uvIndex = "--";
  String _visibility = "--";
  String _sunrise = "--";
  String _sunset = "--";

  int _pressureValue = 0;
  int _uvValue = 0;
  int _humidityValue = 0;
  int _feelsLikeValue = 0;
  double _visibilityValue = 0.0;

  List<Map<String, dynamic>> _hourlyForecast = [];
  List<Map<String, dynamic>> _dailyForecast = [];
  int _hourlyCenterIndex = 2;

  bool _isGpsMode = true;
  List<Map<String, dynamic>> _suggestions = [];

  int _weatherRequestId = 0;
  int _geoRequestId = 0;

  DateTime? _lastFetchTime;

  double? _lastGpsLat;
  double? _lastGpsLon;
  String? _lastGpsCity;
  DateTime? _lastGpsTime;

  // 0 — без фона, 1 — весна, 2 — лето, 3 — осень, 4 — зима
  int _seasonIndex = 0;

  static const String _prefsKeySeason = 'season_index';
  static const Duration _autoRefreshThreshold = Duration(minutes: 5);
  static const Duration _gpsCacheTtl = Duration(minutes: 15);

  static const int _hoursBack = 2;
  static const int _hoursForward = 23;

  static const Color _rainDeep = Color(0xFF0D47A1);
  static const Color _rainMid = Color(0xFF1565C0);
  static const Color _snowColor = Color(0xFFB3E5FC);
  static const Color _boltColor = Color(0xFFFFEB3B);
  static const Color _moonColor = Color(0xFF303F9F);
  static const Color _sunColor = Color(0xFFFFD54F);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _particleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();

    _loadSeasonFromPrefs();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadWeatherByGPS();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _suggestionsOverlayEntry?.remove();
    _suggestionsOverlayEntry = null;
    _particleController.dispose();
    _hourlyScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ==================== ПОГОДНЫЙ ЭФФЕКТ ====================

  _WeatherEffect get _weatherEffect {
    final c = _condition.toLowerCase();
    if (c.contains('гроз') || c.contains('thunder')) {
      return _WeatherEffect.thunder;
    }
    if (c.contains('снег') ||
        c.contains('метел') ||
        c.contains('пург') ||
        c.contains('snow') ||
        c.contains('blizzard')) {
      return _WeatherEffect.snow;
    }
    if (c.contains('дожд') ||
        c.contains('морос') ||
        c.contains('ливень') ||
        c.contains('rain') ||
        c.contains('drizzle') ||
        c.contains('shower')) {
      return _WeatherEffect.rain;
    }
    if (c.contains('туман') ||
        c.contains('мгла') ||
        c.contains('fog') ||
        c.contains('mist')) {
      return _WeatherEffect.fog;
    }
    if (c.contains('пасмурн') || c.contains('overcast')) {
      return _WeatherEffect.overcast;
    }
    if (c.contains('перемен') ||
        c.contains('partly') ||
        (c.contains('облач') && c.contains('небольш'))) {
      return _WeatherEffect.partly;
    }
    if (c.contains('облач') || c.contains('cloud')) {
      return _WeatherEffect.cloudy;
    }
    if (c.contains('ясно') ||
        c.contains('солнеч') ||
        c.contains('clear') ||
        c.contains('sunny')) {
      return _WeatherEffect.sun;
    }
    return _WeatherEffect.none;
  }

  // ==================== СОХРАНЕНИЕ СЕЗОНА ====================

  Future<void> _loadSeasonFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_prefsKeySeason) ?? 0;
      if (!mounted) return;
      if (saved >= 0 && saved <= 4 && saved != _seasonIndex) {
        setState(() => _seasonIndex = saved);
      }
    } catch (_) {}
  }

  Future<void> _saveSeasonToPrefs(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKeySeason, index);
    } catch (_) {}
  }

  // ==================== ХЕЛПЕРЫ КЭША ====================

  bool get _hasGpsCache => _lastGpsLat != null && _lastGpsLon != null;

  bool get _isGpsCacheFresh {
    if (!_hasGpsCache || _lastGpsTime == null) return false;
    return DateTime.now().difference(_lastGpsTime!) < _gpsCacheTtl;
  }

  // ==================== ЖИЗНЕННЫЙ ЦИКЛ ====================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;

    final DateTime now = DateTime.now();
    final bool shouldRefresh = _lastFetchTime == null ||
        now.difference(_lastFetchTime!) >= _autoRefreshThreshold;
    if (!shouldRefresh) return;

    if (_isGpsMode) {
      _loadWeatherByGPS(useCached: true);
    } else {
      _fetchWeather(55.7522, 37.6156, _city);
    }
  }

  // ==================== PULL-TO-REFRESH ====================

  Future<void> _onPullToRefresh() async {
    if (_isGpsMode) {
      await _loadWeatherByGPS(useCached: true);
    } else {
      await _fetchWeather(55.7522, 37.6156, _city);
    }
  }

  // ==================== СВАЙПЫ МЕЖДУ ВКЛАДКАМИ ====================

  void _handleHorizontalSwipe(DragEndDetails details) {
    final double v = details.primaryVelocity ?? 0;
    if (v.abs() < 300) return;

    if (v < 0 && _isGpsMode) {
      _switchToManualMode();
    } else if (v > 0 && !_isGpsMode) {
      _switchToGpsMode();
    }
  }

  // ==================== ПЕРЕКЛЮЧЕНИЕ РЕЖИМОВ ====================

  void _switchToGpsMode() {
    _hideSuggestionsOverlay();

    final String displayCity = _lastGpsCity ?? "Моя локация";

    setState(() {
      _isGpsMode = true;
      _suggestions = [];
      _searchController.clear();
      _city = displayCity;
      if (!_hasGpsCache) {
        _condition = "Поиск GPS...";
      }
    });

    _loadWeatherByGPS(useCached: true);
  }

  void _switchToManualMode() {
    _hideSuggestionsOverlay();
    _weatherRequestId++;
    setState(() {
      _isGpsMode = false;
      _city = "Москва";
      _condition = "Загрузка...";
    });
    _fetchWeather(55.7522, 37.6156, "Москва");
  }

  // ==================== GPS ====================

  Future<void> _loadWeatherByGPS({bool useCached = false}) async {
    final int myId = ++_weatherRequestId;

    if (useCached && _isGpsCacheFresh) {
      await _fetchWeather(
        _lastGpsLat!,
        _lastGpsLon!,
        _lastGpsCity ?? "Моя локация",
        requestId: myId,
      );
      return;
    }

    setState(() {
      _city = _lastGpsCity ?? "Моя локация";
      _condition = "Поиск GPS...";
    });

    try {
      final LocationResult result =
          await _locationService.getCurrentLocation();
      if (myId != _weatherRequestId) return;
      if (!mounted || !_isGpsMode) return;

      if (!result.hasPosition) {
        if (_hasGpsCache) {
          await _fetchWeather(
            _lastGpsLat!,
            _lastGpsLon!,
            _lastGpsCity ?? "Моя локация",
            requestId: myId,
          );
          return;
        }

        String message;
        switch (result.status) {
          case LocationStatus.serviceDisabled:
            message = "Включите геолокацию";
            break;
          case LocationStatus.permissionDenied:
            message = "Нет разрешения на геолокацию";
            break;
          case LocationStatus.timeout:
            message = "Не удалось определить местоположение";
            break;
          case LocationStatus.success:
            message = "Ошибка GPS";
            break;
        }
        setState(() => _condition = message);
        return;
      }

      final double lat = result.latitude!;
      final double lon = result.longitude!;

      _lastGpsLat = lat;
      _lastGpsLon = lon;
      _lastGpsTime = DateTime.now();

      final String? cityName = await _reverseGeocode(lat, lon);
      if (myId != _weatherRequestId) return;
      if (!mounted || !_isGpsMode) return;

      _lastGpsCity = cityName;

      await _fetchWeather(
        lat,
        lon,
        cityName ?? "Моя локация",
        requestId: myId,
      );
    } catch (_) {
      if (myId == _weatherRequestId && mounted && _isGpsMode) {
        setState(() => _condition = "Ошибка GPS");
      }
    }
  }

  Future<String?> _reverseGeocode(double lat, double lon) async {
    try {
      final url = Uri.parse(
          "https://nominatim.openstreetmap.org/reverse"
          "?lat=$lat&lon=$lon&format=json&accept-language=ru&zoom=10");
      final response = await http.get(url, headers: {
        'User-Agent': 'WeatherApp/1.0',
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final item = Map<String, dynamic>.from(decoded);
          final addressRaw = item['address'];
          final Map<String, dynamic> address = addressRaw is Map
              ? Map<String, dynamic>.from(addressRaw)
              : {};
          final name = address['city'] ??
              address['town'] ??
              address['village'] ??
              address['municipality'] ??
              address['hamlet'] ??
              address['county'] ??
              address['state'];
          if (name != null && name.toString().isNotEmpty) {
            return name.toString();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ==================== ОВЕРЛЕЙ ПОДСКАЗОК ====================

  void _updateSuggestionsOverlay() {
    _suggestionsOverlayEntry?.remove();
    _suggestionsOverlayEntry = null;

    if (!mounted) return;
    if (_isGpsMode || _suggestions.isEmpty) return;

    final OverlayState? overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    _suggestionsOverlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned(
          width: MediaQuery.of(context).size.width - 40,
          child: CompositedTransformFollower(
            link: _searchFieldLink,
            showWhenUnlinked: false,
            offset: const Offset(0, 58),
            child: _buildSuggestionsOverlayPanel(),
          ),
        );
      },
    );
    overlay.insert(_suggestionsOverlayEntry!);
  }

  void _hideSuggestionsOverlay() {
    _suggestionsOverlayEntry?.remove();
    _suggestionsOverlayEntry = null;
  }

  Widget _buildSuggestionsOverlayPanel() {
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1.2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _suggestions.length,
                separatorBuilder: (context, index) => const Divider(
                  color: Colors.white10,
                  height: 1,
                ),
                itemBuilder: (context, index) {
                  final city = _suggestions[index];
                  final String name = city['name']?.toString() ?? '';
                  final String country = city['country']?.toString() ?? '';
                  final String region = city['admin1']?.toString() ?? '';

                  return ListTile(
                    title: Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      [region, country]
                          .where((s) => s.isNotEmpty)
                          .join(' · '),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      _hideSuggestionsOverlay();
                      _fetchWeather(
                        city['latitude'] as double,
                        city['longitude'] as double,
                        name,
                      );
                      setState(() {
                        _suggestions = [];
                        _searchController.clear();
                      });
                      FocusScope.of(context).unfocus();
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== ПЕРЕВОД ====================

  String _translateToRussian(String text) {
    final lower = text.toLowerCase().trim();
    const map = <String, String>{
      'sunny': 'Солнечно',
      'clear': 'Ясно',
      'partly cloudy': 'Переменная облачность',
      'cloudy': 'Облачно',
      'overcast': 'Пасмурно',
      'mist': 'Дымка',
      'fog': 'Туман',
      'freezing fog': 'Ледяной туман',
      'patchy rain possible': 'Возможен дождь',
      'patchy rain nearby': 'Местами дождь',
      'light rain': 'Небольшой дождь',
      'moderate rain': 'Умеренный дождь',
      'heavy rain': 'Сильный дождь',
      'light rain shower': 'Небольшой ливень',
      'moderate or heavy rain shower': 'Сильный ливень',
      'torrential rain shower': 'Ливень',
      'light drizzle': 'Лёгкая морось',
      'freezing drizzle': 'Ледяная морось',
      'heavy freezing drizzle': 'Сильная ледяная морось',
      'patchy light drizzle': 'Местами морось',
      'patchy light rain': 'Местами небольшой дождь',
      'patchy moderate rain': 'Местами умеренный дождь',
      'patchy heavy rain': 'Местами сильный дождь',
      'thundery outbreaks possible': 'Возможны грозы',
      'patchy light rain with thunder': 'Местами дождь с грозой',
      'moderate or heavy rain with thunder': 'Сильный дождь с грозой',
      'patchy light snow': 'Местами небольшой снег',
      'patchy moderate snow': 'Местами умеренный снег',
      'patchy heavy snow': 'Местами сильный снег',
      'light snow': 'Небольшой снег',
      'moderate snow': 'Умеренный снег',
      'heavy snow': 'Сильный снег',
      'light snow showers': 'Небольшой снегопад',
      'moderate or heavy snow showers': 'Сильный снегопад',
      'blowing snow': 'Метель',
      'blizzard': 'Пурга',
      'patchy snow possible': 'Возможен снег',
      'patchy sleet possible': 'Возможен мокрый снег',
      'light sleet': 'Небольшой мокрый снег',
      'moderate or heavy sleet': 'Сильный мокрый снег',
      'light freezing rain': 'Небольшой ледяной дождь',
      'moderate or heavy freezing rain': 'Сильный ледяной дождь',
      'patchy freezing drizzle possible': 'Возможна ледяная морось',
      'ice pellets': 'Ледяной дождь',
      'light showers of ice pellets': 'Небольшой ледяной дождь',
      'moderate or heavy showers of ice pellets': 'Сильный ледяной дождь',
    };
    return map[lower] ?? text;
  }

  // ==================== ХЕЛПЕРЫ ПОГОДЫ ====================

  String _extractDesc(Map<String, dynamic> item) {
    final langRu = item['lang_ru'];
    if (langRu is List && langRu.isNotEmpty) {
      final first = langRu[0];
      if (first is Map && first['value'] != null) {
        final val = first['value'].toString().trim();
                if (val.isNotEmpty) return _translateToRussian(val);
      }
    }
    final desc = item['weatherDesc'];
    if (desc is List && desc.isNotEmpty) {
      final first = desc[0];
      if (first is Map && first['value'] != null) {
        return _translateToRussian(first['value'].toString());
      }
    }
    return '--';
  }

  double _parseTimeOfDay(String s, {required double fallback}) {
    final parts = s.split(':');
    if (parts.length != 2) return fallback;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return fallback;
    return h + m / 60.0;
  }

  bool _isTuman(String c) =>
      c.contains('туман') ||
      c.contains('мгла') ||
      c.contains('fog') ||
      c.contains('mist');

  bool _isOvercast(String c) =>
      c.contains('пасмурн') || c.contains('overcast');

  bool _isPartly(String c) =>
      c.contains('перемен') ||
      c.contains('partly') ||
      (c.contains('облач') && c.contains('небольш'));

  bool _hasRain(String c) =>
      c.contains('дожд') ||
      c.contains('морос') ||
      c.contains('ливень') ||
      c.contains('rain') ||
      c.contains('drizzle') ||
      c.contains('shower');

  bool _hasThunder(String c) => c.contains('гроз') || c.contains('thunder');

  bool _hasSnow(String c) =>
      c.contains('снег') ||
      c.contains('метел') ||
      c.contains('пург') ||
      c.contains('snow') ||
      c.contains('blizzard');

  bool _hasClouds(String c) =>
      c.contains('облач') || c.contains('cloud') || _isOvercast(c);

  bool _isClear(String c) =>
      c.contains('ясно') ||
      c.contains('солнеч') ||
      c.contains('clear') ||
      c.contains('sunny');

  // ==================== ИКОНКИ ПОГОДЫ ====================

  Widget _cloudStack({double size = 28, double intensity = 1.0}) {
    final double t = ((intensity - 0.5) / 0.7).clamp(0.0, 1.0);
    final Color baseColor = Color.lerp(
      const Color(0xFFCFD8DC),
      const Color(0xFF90A4AE),
      t,
    )!;
    final Color lightColor = Color.lerp(
      const Color(0xFFECEFF1),
      const Color(0xFFCFD8DC),
      t,
    )!;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            bottom: 0,
            child: Icon(Icons.cloud, size: size * 0.75, color: baseColor),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: Icon(Icons.cloud, size: size * 0.75, color: lightColor),
          ),
        ],
      ),
    );
  }

  Widget _fogIcon({double size = 28}) {
    return SizedBox(
      width: size,
      height: size,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud, size: size * 0.55, color: const Color(0xFFB0BEC5)),
          const SizedBox(height: 3),
          Container(
            width: size * 0.85,
            height: 1.6,
            decoration: BoxDecoration(
              color: const Color(0xFFECEFF1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 3),
          Container(
            width: size * 0.6,
            height: 1.6,
            decoration: BoxDecoration(
              color: const Color(0xFFECEFF1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rainOnlyIcon({required double size}) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: size * 0.08,
            top: size * 0.12,
            child: Icon(
              Icons.water_drop,
              size: size * 0.38,
              color: _rainMid,
            ),
          ),
          Positioned(
            right: size * 0.08,
            top: size * 0.12,
            child: Icon(
              Icons.water_drop,
              size: size * 0.38,
              color: _rainMid,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: size * 0.05,
            child: Center(
              child: Icon(
                Icons.water_drop,
                size: size * 0.5,
                color: _rainDeep,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _snowOnlyIcon({required double size}) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: size * 0.08,
            top: size * 0.12,
            child: Icon(
              Icons.ac_unit,
              size: size * 0.38,
              color: _snowColor,
            ),
          ),
          Positioned(
            right: size * 0.08,
            top: size * 0.12,
            child: Icon(
              Icons.ac_unit,
              size: size * 0.38,
              color: _snowColor,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: size * 0.05,
            child: Center(
              child: Icon(
                Icons.ac_unit,
                size: size * 0.5,
                color: _snowColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _boltOnlyIcon({required double size}) {
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Icon(
          Icons.bolt,
          size: size * 0.85,
          color: _boltColor,
        ),
      ),
    );
  }

  Widget _precipitationOnlyIcon({
    required double size,
    required bool hasRain,
    required bool hasThunder,
    required bool hasSnow,
  }) {
    if (hasThunder) return _boltOnlyIcon(size: size);
    if (hasSnow) return _snowOnlyIcon(size: size);
    if (hasRain) return _rainOnlyIcon(size: size);
    return SizedBox(width: size, height: size);
  }

  Widget _cloudWithPrecipitationIcon({
    required double size,
    required bool hasRain,
    required bool hasThunder,
    required bool hasSnow,
    double intensity = 1.0,
  }) {
    Widget? below;
    if (hasThunder) {
      below = Icon(Icons.bolt, size: size * 0.55, color: _boltColor);
    } else if (hasSnow) {
      below = Icon(Icons.ac_unit, size: size * 0.5, color: _snowColor);
    } else if (hasRain) {
      below = Icon(Icons.water_drop, size: size * 0.5, color: _rainDeep);
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: _cloudStack(size: size * 0.85, intensity: intensity),
            ),
          ),
          if (below != null)
            Positioned(
              bottom: 0,
              right: size * 0.08,
              child: below,
            ),
        ],
      ),
    );
  }

  Widget _weatherIconWidget(
    String condition, {
    double size = 28,
    bool isNight = false,
  }) {
    final c = condition.toLowerCase();

    if (_isTuman(c)) return _fogIcon(size: size);

    final bool hasRain = _hasRain(c);
    final bool hasThunder = _hasThunder(c);
    final bool hasSnow = _hasSnow(c);
    final bool hasClouds = _hasClouds(c);
    final bool isOvercast = _isOvercast(c);
    final bool isPartly = _isPartly(c);
    final bool isClear = _isClear(c);

    final bool hasPrecip = hasRain || hasThunder || hasSnow;

    final Widget luminary = isNight
        ? Icon(Icons.nightlight_round, size: size * 0.75, color: _moonColor)
        : Icon(Icons.wb_sunny, size: size * 0.78, color: _sunColor);

    if (isPartly && !hasPrecip) {
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            Positioned(top: 0, right: 0, child: luminary),
            Positioned(
              bottom: 0,
              left: 0,
              child: _cloudStack(size: size * 0.85, intensity: 1.0),
            ),
          ],
        ),
      );
    }

    if (isClear && !hasClouds && !hasPrecip) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(child: luminary),
      );
    }

    if (hasPrecip && !hasClouds && !isOvercast) {
      return _precipitationOnlyIcon(
        size: size,
        hasRain: hasRain,
        hasThunder: hasThunder,
        hasSnow: hasSnow,
      );
    }

    if (isOvercast && !hasPrecip) {
      return _cloudStack(size: size, intensity: 1.2);
    }

    if (hasPrecip) {
      return _cloudWithPrecipitationIcon(
        size: size,
        hasRain: hasRain,
        hasThunder: hasThunder,
        hasSnow: hasSnow,
        intensity: isOvercast ? 1.2 : 1.0,
      );
    }

    if (hasClouds) {
      return _cloudStack(size: size, intensity: 1.0);
    }

    return _cloudStack(size: size, intensity: 1.0);
  }

  String _formatDay(String date) {
    try {
      final d = DateTime.parse(date);
      final now = DateTime.now();
      if (d.year == now.year && d.month == now.month && d.day == now.day) {
        return "Сегодня";
      }
      const days = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
      return days[d.weekday - 1];
    } catch (_) {
      return date;
    }
  }

  // ==================== ГРАДАЦИИ ====================

  String _uvLabel(int uv) {
    if (uv <= 2) return 'Низкий';
    if (uv <= 5) return 'Средний';
    if (uv <= 7) return 'Высокий';
    if (uv <= 10) return 'Очень высокий';
    return 'Экстремальный';
  }

  Color _uvColor(int uv) {
    if (uv <= 2) return const Color(0xFF4CAF50);
    if (uv <= 5) return const Color(0xFFFFC107);
    if (uv <= 7) return const Color(0xFFFF9800);
    if (uv <= 10) return const Color(0xFFF44336);
    return const Color(0xFF9C27B0);
  }

  String _pressureLabel(int p) {
    if (p <= 0) return '--';
    if (p < 745) return 'Низкое';
    if (p <= 765) return 'Норма';
    return 'Высокое';
  }

  Color _pressureColor(int p) {
    if (p <= 0) return const Color(0xFF90A4AE);
    if (p < 745) return const Color(0xFF42A5F5);
    if (p <= 765) return const Color(0xFF4CAF50);
    return const Color(0xFFFF9800);
  }

  String _visibilityLabel(double v) {
    if (v <= 0) return '--';
    if (v < 1) return 'Плохая';
    if (v < 5) return 'Средняя';
    if (v < 10) return 'Хорошая';
    return 'Отличная';
  }

  Color _visibilityColor(double v) {
    if (v <= 0) return const Color(0xFF90A4AE);
    if (v < 1) return const Color(0xFFF44336);
    if (v < 5) return const Color(0xFFFF9800);
    if (v < 10) return const Color(0xFF4CAF50);
    return const Color(0xFF00BFA5);
  }

  String _comfortLabel(int t) {
    if (t <= 0) return 'Холодно';
    if (t <= 10) return 'Прохладно';
    if (t <= 20) return 'Комфортно';
    if (t <= 28) return 'Тепло';
    return 'Жарко';
  }

  Color _comfortColor(int t) {
    if (t <= 0) return const Color(0xFF64B5F6);
    if (t <= 10) return const Color(0xFF4FC3F7);
    if (t <= 20) return const Color(0xFF4CAF50);
    if (t <= 28) return const Color(0xFFFF9800);
    return const Color(0xFFF44336);
  }

  // ==================== ИКОНКА ВЛАЖНОСТИ ====================

  Widget _humidityIcon({double size = 26}) {
    final int p = _humidityValue.clamp(0, 100);
    final double fraction = p / 100.0;
    return SizedBox(
      width: size * 0.72,
      height: size,
      child: CustomPaint(
        painter: _DropletPainter(
          fillFraction: fraction,
          baseColor: Colors.white38,
          fillColor: const Color(0xFF64B5F6),
          outlineColor: Colors.white70,
        ),
      ),
    );
  }

  // ==================== ПРОКРУТКА ====================

  void _scrollHourlyToCenter() {
    if (!_hourlyScrollController.hasClients) return;
    if (_hourlyCenterIndex < 0 ||
        _hourlyCenterIndex >= _hourlyForecast.length) {
      return;
    }
    const double itemWidth = 72.0;
    const double separator = 10.0;
    const double paddingLeft = 16.0;

    final double viewport =
        _hourlyScrollController.position.viewportDimension;
    final double itemCenter = paddingLeft +
        _hourlyCenterIndex * (itemWidth + separator) +
        itemWidth / 2.0;
    final double target = itemCenter - viewport / 2.0;

    final double clamped = target.clamp(
      0.0,
      _hourlyScrollController.position.maxScrollExtent,
    );

    _hourlyScrollController.jumpTo(clamped);
  }

  // ==================== ЗАПРОС ПОГОДЫ ====================

  Future<void> _fetchWeather(
    double lat,
    double lon,
    String cityName, {
    int? requestId,
  }) async {
    final int myId = requestId ?? ++_weatherRequestId;
    try {
      final url = Uri.parse("https://wttr.in/$lat,$lon?format=j1&lang=ru");
      final response =
          await http.get(url).timeout(const Duration(seconds: 10));

      if (myId != _weatherRequestId) return;

      if (response.statusCode != 200) {
        if (mounted) {
          setState(
              () => _condition = "Ошибка сервера ${response.statusCode}");
        }
        return;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        if (mounted) setState(() => _condition = "Неверный формат ответа");
        return;
      }
      final data = Map<String, dynamic>.from(decoded);

      final currentRaw = data['current_condition'];
      final List<dynamic> currentList =
          currentRaw is List ? currentRaw : const [];
      if (currentList.isEmpty || currentList.first is! Map) {
        if (mounted) setState(() => _condition = "Нет текущих данных");
        return;
      }
      final current = Map<String, dynamic>.from(currentList.first as Map);

      final weatherRaw = data['weather'];
      final List<dynamic> weatherList =
          weatherRaw is List ? weatherRaw : const [];

      final String cond = _extractDesc(current);

      String sunrise = "--";
      String sunset = "--";
      if (weatherList.isNotEmpty && weatherList.first is Map) {
        final w0 = Map<String, dynamic>.from(weatherList.first as Map);
        final astroRaw = w0['astronomy'];
        final List<dynamic> astroList =
            astroRaw is List ? astroRaw : const [];
        if (astroList.isNotEmpty && astroList.first is Map) {
          final astro = Map<String, dynamic>.from(astroList.first as Map);
          sunrise = (astro['sunrise'] ?? '--').toString();
          sunset = (astro['sunset'] ?? '--').toString();
        }
      }
      final double sunriseHour = _parseTimeOfDay(sunrise, fallback: 6.0);
      final double sunsetHour = _parseTimeOfDay(sunset, fallback: 20.0);

      final List<Map<String, dynamic>> readings = [];
      for (final dayRaw in weatherList) {
        if (dayRaw is! Map) continue;
        final day = Map<String, dynamic>.from(dayRaw);
        final String dateStr = (day['date'] ?? '').toString();
        final List<dynamic> hList =
            day['hourly'] is List ? day['hourly'] : const [];

        for (final rawH in hList) {
          if (rawH is! Map) continue;
          final h = Map<String, dynamic>.from(rawH);

          final int timeInt =
              int.tryParse((h['time'] ?? '0').toString()) ?? 0;
          final int hour = timeInt ~/ 100;

          DateTime? dt;
          try {
            final parts = dateStr.split('-');
            dt = DateTime(
              int.parse(parts[0]),
              int.parse(parts[1]),
              int.parse(parts[2]),
              hour,
            );
          } catch (_) {
            dt = null;
          }
          if (dt == null) continue;

          readings.add({
            'datetime': dt,
            'temp': (h['tempC'] ?? '--').toString(),
            'condition': _extractDesc(h),
          });
        }
      }
      readings.sort((a, b) {
        final da = a['datetime'] as DateTime;
        final db = b['datetime'] as DateTime;
        return da.compareTo(db);
      });

      final DateTime now = DateTime.now();
      final DateTime nowHour =
          DateTime(now.year, now.month, now.day, now.hour);
      final DateTime today = DateTime(now.year, now.month, now.day);

      final List<Map<String, dynamic>> hourly = [];
      int centerIdx = _hoursBack;

      for (int offset = -_hoursBack; offset <= _hoursForward; offset++) {
        final DateTime target = nowHour.add(Duration(hours: offset));

        Map<String, dynamic>? nearest;
        Duration minDiff = const Duration(days: 365);
        for (final r in readings) {
          final DateTime rd = r['datetime'] as DateTime;
          final Duration diff = rd.difference(target).abs();
          if (diff < minDiff) {
            minDiff = diff;
            nearest = r;
          }
        }

        final bool isNow = offset == 0;
        if (isNow) centerIdx = hourly.length;

        final DateTime targetDay =
            DateTime(target.year, target.month, target.day);
        final int dayDelta = targetDay.difference(today).inDays;

        String dateLabel;
        if (dayDelta == 0) {
          dateLabel = "Сегодня";
        } else if (dayDelta == 1) {
          dateLabel = "Завтра";
        } else if (dayDelta == -1) {
          dateLabel = "Вчера";
        } else {
          dateLabel =
              "${target.day.toString().padLeft(2, '0')}.${target.month.toString().padLeft(2, '0')}";
        }

        final double hd = target.hour.toDouble();
        final bool isNight = hd < sunriseHour || hd >= sunsetHour;

        hourly.add({
          'hour': target.hour,
          'dateLabel': dateLabel,
          'temp': nearest?['temp'] ?? '--',
          'condition': nearest?['condition'] ?? '--',
          'isNow': isNow,
          'isNight': isNight,
        });
      }

      final List<Map<String, dynamic>> daily = [];
      for (final rawD in weatherList) {
        if (rawD is! Map) continue;
        final d = Map<String, dynamic>.from(rawD);
        final hRaw = d['hourly'];
        final List<dynamic> hList = hRaw is List ? hRaw : const [];
        if (hList.isEmpty) continue;

        final int dayIdx = hList.length > 4 ? 4 : 0;
        final int nightIdx = hList.length > 7 ? 7 : hList.length - 1;

        final Map<String, dynamic> dayHour = hList[dayIdx] is Map
            ? Map<String, dynamic>.from(hList[dayIdx])
            : {};
        final Map<String, dynamic> nightHour = hList[nightIdx] is Map
            ? Map<String, dynamic>.from(hList[nightIdx])
            : {};

        daily.add({
          'date': (d['date'] ?? '').toString(),
          'max': (d['maxtempC'] ?? '--').toString(),
          'min': (d['mintempC'] ?? '--').toString(),
          'dayCondition': _extractDesc(dayHour),
          'nightCondition': _extractDesc(nightHour),
        });
      }

      final int pressureInt =
          int.tryParse((current['pressure'] ?? '0').toString()) ?? 0;
      final int uvInt =
          int.tryParse((current['uvIndex'] ?? '0').toString()) ?? 0;
      final int humidityInt =
          int.tryParse((current['humidity'] ?? '0').toString()) ?? 0;
      final int feelsInt =
          int.tryParse((current['FeelsLikeC'] ?? '0').toString()) ?? 0;
      final double visibilityDouble =
          double.tryParse((current['visibility'] ?? '0').toString()) ?? 0.0;

      if (myId != _weatherRequestId) return;
      if (!mounted) return;
      setState(() {
        _city = cityName;
        _temp = "${current['temp_C'] ?? '--'}°";
        _condition = cond;
        _wind = "${current['windspeedKmph'] ?? '--'} км/ч";
        _humidity = "$humidityInt%";
        _feelsLike = "$feelsInt°";
        _pressure = "$pressureInt мм рт. ст.";
        _uvIndex = "$uvInt";
        _visibility = "$visibilityDouble км";
        _sunrise = sunrise;
        _sunset = sunset;

        _pressureValue = pressureInt;
        _uvValue = uvInt;
        _humidityValue = humidityInt;
        _feelsLikeValue = feelsInt;
        _visibilityValue = visibilityDouble;

        _hourlyForecast = hourly;
        _dailyForecast = daily;
        _hourlyCenterIndex = centerIdx;

        _lastFetchTime = DateTime.now();
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollHourlyToCenter();
      });
    } catch (e, st) {
      debugPrint("WEATHER ERROR: $e\n$st");
      if (myId == _weatherRequestId && mounted) {
        setState(() => _condition = "Ошибка: $e");
      }
    }
  }

  // ==================== ПОИСК ====================

  void _onSearchChanged(String text) async {
    if (_isGpsMode || text.trim().length < 2) {
      setState(() => _suggestions = []);
      _hideSuggestionsOverlay();
      return;
    }

    final int myId = ++_geoRequestId;

    try {
      final url = Uri.parse(
          "https://nominatim.openstreetmap.org/search"
          "?q=${Uri.encodeComponent(text)}"
          "&format=json&limit=5&accept-language=ru&addressdetails=1");

      final response = await http.get(url, headers: {
        'User-Agent': 'WeatherApp/1.0',
      }).timeout(const Duration(seconds: 10));

      if (myId != _geoRequestId) return;
      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          setState(() => _suggestions = []);
          _hideSuggestionsOverlay();
          return;
        }

        setState(() {
          _suggestions = decoded
              .whereType<Map>()
              .map<Map<String, dynamic>>((raw) {
            final item = Map<String, dynamic>.from(raw);

            final addressRaw = item['address'];
            final Map<String, dynamic> address = addressRaw is Map
                ? Map<String, dynamic>.from(addressRaw)
                : {};

            final String displayName =
                (item['display_name'] ?? '').toString();
            final String name = (address['city'] ??
                    address['town'] ??
                    address['village'] ??
                    address['municipality'] ??
                    address['hamlet'] ??
                    (displayName.contains(',')
                        ? displayName.split(',').first.trim()
                        : displayName))
                .toString();

            final String region = (address['state'] ??
                    address['region'] ??
                    address['county'] ??
                    address['state_district'] ??
                    '')
                .toString();

            final String country = (address['country'] ?? '').toString();

            final double? lat = double.tryParse('${item['lat']}');
            final double? lon = double.tryParse('${item['lon']}');

            return {
              'name': name,
              'latitude': lat ?? 0.0,
              'longitude': lon ?? 0.0,
              'country': country,
              'admin1': region,
            };
          }).where((e) => (e['latitude'] as double) != 0.0).toList();
        });
        _updateSuggestionsOverlay();
        return;
      }
    } catch (e) {
      debugPrint("GEO ERROR: $e");
    }
    if (myId == _geoRequestId && mounted) {
      setState(() => _suggestions = []);
      _hideSuggestionsOverlay();
    }
  }

  // ==================== ПОДБОР ФОНА ====================

  void _showSeasonPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => _buildSeasonPickerSheet(ctx),
    );
  }

  Widget _buildSeasonPickerSheet(BuildContext ctx) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        decoration: BoxDecoration(
          color: const Color(0xFF2E4A78).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Фон погоды",
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "Выберите сезонное оформление",
              style: TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 5,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) => _buildSeasonPreview(i, ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeasonPreview(int index, BuildContext sheetContext) {
    final bool selected = _seasonIndex == index;
    return GestureDetector(
      onTap: () {
        setState(() => _seasonIndex = index);
        _saveSeasonToPrefs(index);
        Navigator.of(sheetContext).pop();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.20),
                width: selected ? 2 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: AppColors.dayGradient,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SeasonalBackgroundPainter(
                      season: index,
                      progress: 0.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _seasonName(index),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _seasonName(int i) {
    switch (i) {
      case 0:
        return 'Нет';
      case 1:
        return 'Весна';
      case 2:
        return 'Лето';
      case 3:
        return 'Осень';
      case 4:
        return 'Зима';
    }
    return '';
  }

  // ==================== ВИДЖЕТЫ ====================

  Widget _buildHourlyForecast() {
    if (_hourlyForecast.isEmpty) return const SizedBox.shrink();

    const double itemWidth = 72.0;
    const double separator = 10.0;
    const double itemHeight = 148.0;

    return _buildGlassPanel(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: SizedBox(
        height: itemHeight,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
            },
          ),
          child: ListView.separated(
            controller: _hourlyScrollController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _hourlyForecast.length,
            separatorBuilder: (_, _) => const SizedBox(width: separator),
            itemBuilder: (context, i) {
              final h = _hourlyForecast[i];
              final bool isNow = h['isNow'] == true;
              final bool isNight = h['isNight'] == true;
              final int hour = (h['hour'] as int?) ?? 0;
              final String timeLabel =
                  "${hour.toString().padLeft(2, '0')}:00";
              final String dateLabel = (h['dateLabel'] ?? '').toString();

              return Container(
                width: itemWidth,
                decoration: isNow
                    ? BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.35),
                          width: 1.2,
                        ),
                      )
                    : null,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      dateLabel,
                      style: TextStyle(
                        color: isNow ? Colors.white70 : Colors.white38,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isNow ? "Сейчас" : timeLabel,
                      style: TextStyle(
                        color: isNow ? Colors.white : Colors.white70,
                        fontSize: 13,
                        fontWeight:
                            isNow ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (isNow)
                      Text(
                        timeLabel,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    if (!isNow) const SizedBox(height: 13),
                    const SizedBox(height: 6),
                    _weatherIconWidget(
                      h['condition'] as String,
                      size: 28,
                      isNight: isNight,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "${h['temp']}°",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDailyForecast() {
    if (_dailyForecast.isEmpty) return const SizedBox.shrink();
    return _buildGlassPanel(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 8),
            child: Row(
              children: [
                const SizedBox(width: 70),
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.wb_sunny_outlined,
                          size: 13,
                          color: Colors.white54,
                        ),
                        SizedBox(width: 4),
                        Text(
                          "День",
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.nightlight_outlined,
                          size: 13,
                          color: Colors.white54,
                        ),
                        SizedBox(width: 4),
                        Text(
                          "Ночь",
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(
            color: Colors.white.withValues(alpha: 0.12),
            height: 1,
          ),
          for (int i = 0; i < _dailyForecast.length; i++) ...[
            if (i > 0)
              Divider(
                color: Colors.white.withValues(alpha: 0.08),
                height: 1,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 70,
                    child: Text(
                      _formatDay(_dailyForecast[i]['date'] as String),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _weatherIconWidget(
                          (_dailyForecast[i]['dayCondition'] ?? '--')
                              as String,
                          size: 30,
                          isNight: false,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "${_dailyForecast[i]['max']}°",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _weatherIconWidget(
                          (_dailyForecast[i]['nightCondition'] ?? '--')
                              as String,
                          size: 30,
                          isNight: true,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "${_dailyForecast[i]['min']}°",
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailsGrid() {
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildDetailCard(
                  Icons.thermostat,
                  "Ощущается",
                  _feelsLike,
                  badge: _comfortLabel(_feelsLikeValue),
                  badgeColor: _comfortColor(_feelsLikeValue),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildDetailCard(
                  Icons.speed,
                  "Давление",
                  _pressure,
                  badge: _pressureLabel(_pressureValue),
                  badgeColor: _pressureColor(_pressureValue),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildDetailCard(
                  Icons.wb_sunny_outlined,
                  "УФ-индекс",
                  _uvIndex,
                  badge: _uvLabel(_uvValue),
                  badgeColor: _uvColor(_uvValue),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildDetailCard(
                  Icons.visibility_outlined,
                  "Видимость",
                  _visibility,
                  badge: _visibilityLabel(_visibilityValue),
                  badgeColor: _visibilityColor(_visibilityValue),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildDetailCard(
                  Icons.wb_twilight,
                  "Восход",
                  _sunrise,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildDetailCard(
                  Icons.nights_stay_outlined,
                  "Закат",
                  _sunset,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDetailCard(
    IconData icon,
    String title,
    String value, {
    String? badge,
    Color? badgeColor,
  }) {
    final bool hasBadge = badge != null && badge != '--';
    final Color base = badgeColor ?? const Color(0xFF90A4AE);

    return _buildGlassPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white70, size: 18),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (hasBadge) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: base.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: base.withValues(alpha: 0.45),
                  width: 1,
                ),
              ),
              child: Text(
                badge,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGlassPanel({
    required Widget child,
    EdgeInsetsGeometry? padding,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: double.infinity,
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
              width: 1.2,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildDetailItem(Widget icon, String title, String value) {
    return Column(
      children: [
        icon,
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // ==================== КНОПКА ВЫБОРА ФОНА ====================

  Widget _buildSeasonButton() {
    final bool hasBackground = _seasonIndex != 0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _showSeasonPicker,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: hasBackground ? 0.18 : 0.10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Icon(
            hasBackground ? Icons.landscape : Icons.landscape_outlined,
            color: Colors.white.withValues(alpha: 0.85),
            size: 20,
          ),
        ),
      ),
    );
  }

  // ==================== ПЛАВНЫЙ КОНТЕНТ ====================

  Widget _buildAnimatedWeatherContent() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.03),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: Alignment.topCenter,
          children: <Widget>[
            ...previousChildren,
            ?currentChild,
          ],
        );
      },
      child: Column(
        key: ValueKey<bool>(_isGpsMode),
        children: [
          const SizedBox(height: 50),
          Text(
            _temp,
            style: const TextStyle(
              fontSize: 102,
              fontWeight: FontWeight.w100,
              color: Colors.white,
            ),
          ),
          Text(
            _condition,
            style: const TextStyle(
              fontSize: 22,
              color: Colors.white70,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 50),
        ],
      ),
    );
  }

  // ==================== BUILD ====================

  @override
  Widget build(BuildContext context) {
    final double bottomPadding = MediaQuery.of(context).padding.bottom;
    final double screenHeight = MediaQuery.of(context).size.height;
    final _WeatherEffect effect = _weatherEffect;

    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: AppColors.dayGradient,
              ),
            ),
          ),

          // Слои фона: сезон + погодные эффекты, общий ShaderMask затухания
          if (_seasonIndex != 0 || effect != _WeatherEffect.none)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: screenHeight * 0.62,
              child: IgnorePointer(
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.65, 1.0],
                  ).createShader(rect),
                  child: AnimatedBuilder(
                    animation: _particleController,
                    builder: (context, _) {
                      return Stack(
                        children: [
                          if (_seasonIndex != 0)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _SeasonalBackgroundPainter(
                                  season: _seasonIndex,
                                  progress: _particleController.value,
                                ),
                              ),
                            ),
                          if (effect != _WeatherEffect.none)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _WeatherEffectsPainter(
                                  effect: effect,
                                  progress: _particleController.value,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),

          SafeArea(
            bottom: false,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: _handleHorizontalSwipe,
              child: RefreshIndicator(
                color: Colors.white,
                backgroundColor: const Color(0xFF2E4A78),
                displacement: 40,
                onRefresh: _onPullToRefresh,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      floating: false,
                      snap: false,
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      centerTitle: true,
                      toolbarHeight: 64,
                      automaticallyImplyLeading: false,
                      flexibleSpace: ClipRect(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: Container(
                            color: Colors.white.withValues(alpha: 0.05),
                          ),
                        ),
                      ),
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isGpsMode) ...[
                            const Icon(
                              Icons.my_location,
                              color: Colors.white,
                              size: 22,
                            ),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 350),
                              child: Text(
                                _city,
                                key: ValueKey<String>(_city),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 26,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          children: [
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      onTap: _switchToGpsMode,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _isGpsMode
                                              ? Colors.white
                                                  .withValues(alpha: 0.2)
                                              : Colors.transparent,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: const Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.gps_fixed, size: 16),
                                            SizedBox(width: 6),
                                            Text("По GPS"),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: InkWell(
                                      onTap: _switchToManualMode,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: !_isGpsMode
                                              ? Colors.white
                                                  .withValues(alpha: 0.2)
                                              : Colors.transparent,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: const Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.edit_location_alt,
                                              size: 16,
                                            ),
                                            SizedBox(width: 6),
                                            Text("Ручной ввод"),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),

                            if (!_isGpsMode)
                              CompositedTransformTarget(
                                link: _searchFieldLink,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(
                                        sigmaX: 10, sigmaY: 10),
                                    child: Container(
                                      height: 52,
                                      color: Colors.white
                                          .withValues(alpha: 0.15),
                                      child: TextField(
                                        controller: _searchController,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                        ),
                                        onChanged: _onSearchChanged,
                                        decoration: const InputDecoration(
                                          hintText:
                                              "Начните вводить город...",
                                          hintStyle: TextStyle(
                                            color: Colors.white54,
                                            fontSize: 15,
                                          ),
                                          border: InputBorder.none,
                                          prefixIcon: Icon(
                                            Icons.search,
                                            color: Colors.white70,
                                            size: 22,
                                          ),
                                          contentPadding:
                                              EdgeInsets.symmetric(
                                                  vertical: 15),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                            _buildAnimatedWeatherContent(),

                            Align(
                              alignment: Alignment.centerRight,
                              child: _buildSeasonButton(),
                            ),
                            const SizedBox(height: 8),

                            _buildGlassPanel(
                              padding: const EdgeInsets.all(24),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  _buildDetailItem(
                                    const Icon(
                                      Icons.air,
                                      color: Colors.white70,
                                      size: 26,
                                    ),
                                    "Ветер",
                                    _wind,
                                  ),
                                  Container(
                                    width: 1,
                                    height: 40,
                                    color:
                                        Colors.white.withValues(alpha: 0.2),
                                  ),
                                  _buildDetailItem(
                                    _humidityIcon(size: 26),
                                    "Влажность",
                                    _humidity,
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 16),
                            _buildHourlyForecast(),

                            const SizedBox(height: 16),
                            _buildDailyForecast(),

                            const SizedBox(height: 16),
                            _buildDetailsGrid(),

                            SizedBox(height: bottomPadding + 40),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== ТИП ПОГОДНОГО ЭФФЕКТА ====================

enum _WeatherEffect {
  none,
  sun,
  partly,
  cloudy,
  overcast,
  rain,
  snow,
  thunder,
  fog,
}

// ==================== ПОГОДНЫЕ ЭФФЕКТЫ НА ФОНЕ ====================

class _WeatherEffectsPainter extends CustomPainter {
  final _WeatherEffect effect;
  final double progress;

  const _WeatherEffectsPainter({
    required this.effect,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (effect == _WeatherEffect.none) return;

    final double w = size.width;
    final double h = size.height;

    switch (effect) {
      case _WeatherEffect.sun:
        _paintSunRays(canvas, w, h);
        break;

      case _WeatherEffect.partly:
        _paintSunRays(canvas, w, h, intensity: 0.55);
        _paintClouds(canvas, w, h, count: 2, darkness: 0.6);
        break;

      case _WeatherEffect.cloudy:
        _paintClouds(canvas, w, h, count: 3, darkness: 0.75);
        break;

      case _WeatherEffect.overcast:
        _paintClouds(canvas, w, h, count: 6, darkness: 1.0);
        break;

      case _WeatherEffect.rain:
        _paintClouds(canvas, w, h, count: 3, darkness: 0.9);
        _paintRain(canvas, w, h);
        break;

      case _WeatherEffect.snow:
        _paintClouds(canvas, w, h, count: 2, darkness: 0.55);
        _paintSnowfall(canvas, w, h);
        break;

      case _WeatherEffect.thunder:
        _paintClouds(canvas, w, h, count: 5, darkness: 1.0);
        _paintThunder(canvas, w, h);
        break;

      case _WeatherEffect.fog:
        _paintFog(canvas, w, h);
        break;

      case _WeatherEffect.none:
        break;
    }
  }

  // ---------- ЛУЧИ СОЛНЦА ----------
  void _paintSunRays(
    Canvas canvas,
    double w,
    double h, {
    double intensity = 1.0,
  }) {
      final Offset origin = Offset(w * 0.85, h * 0.18);
    
    // Мягкое свечение вокруг
    final double glowR = w * 0.22 * intensity;
    canvas.drawCircle(
      origin,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFFFF59D).withValues(alpha: 0.32 * intensity),
            const Color(0xFFFFF59D).withValues(alpha: 0.0),
          ],
        ).createShader(
            Rect.fromCircle(center: origin, radius: glowR)),
    );

    // Лучи
    const int rayCount = 9;
    for (int i = 0; i < rayCount; i++) {
      final double t = i / (rayCount - 1);
      final double angle = -math.pi * 0.05 - t * math.pi * 0.9;
      final double rayLength = h * (0.42 + (i % 3) * 0.08) * intensity;
      final double rayWidth = w * (0.014 + (i % 2) * 0.010);

      final double endX = origin.dx + math.cos(angle) * rayLength;
      final double endY = origin.dy + math.sin(angle) * rayLength;

      final Path rayPath = Path();
      final double perpAngle = angle + math.pi / 2;
      final double dx = math.cos(perpAngle) * rayWidth / 2;
      final double dy = math.sin(perpAngle) * rayWidth / 2;

      rayPath.moveTo(origin.dx + dx, origin.dy + dy);
      rayPath.lineTo(endX + dx * 0.35, endY + dy * 0.35);
      rayPath.lineTo(endX - dx * 0.35, endY - dy * 0.35);
      rayPath.lineTo(origin.dx - dx, origin.dy - dy);
      rayPath.close();

      final Paint paint = Paint()
        ..shader = ui.Gradient.linear(
          origin,
          Offset(endX, endY),
          [
            const Color(0xFFFFF59D)
                .withValues(alpha: 0.35 * intensity),
            const Color(0xFFFFF59D).withValues(alpha: 0.0),
          ],
        );

      canvas.drawPath(rayPath, paint);
    }
  }

  // ---------- МЯГКИЕ ОБЛАКА ----------
  void _paintClouds(
    Canvas canvas,
    double w,
    double h, {
    required int count,
    required double darkness,
  }) {
    final math.Random rng = math.Random(7919 + count);

    for (int i = 0; i < count; i++) {
      final double cx =
          w * (0.10 + rng.nextDouble() * 0.80);
            final double cy =
          h * (0.18 + rng.nextDouble() * 0.26);
            final double baseR = w * (0.18 + rng.nextDouble() * 0.16);
            final double alpha = (0.20 + rng.nextDouble() * 0.12) * darkness;
      // Дышит по фазе
      final double drift = math.sin(progress * 6.28 + i) * 0.02;
      final Offset center = Offset(cx + w * drift, cy);

      // Три «пуфа» на облако
      _drawPuff(canvas, center, baseR, alpha);
      _drawPuff(
        canvas,
        Offset(center.dx + baseR * 0.7, center.dy + baseR * 0.15),
        baseR * 0.75,
        alpha * 0.9,
      );
      _drawPuff(
        canvas,
        Offset(center.dx - baseR * 0.65, center.dy + baseR * 0.18),
        baseR * 0.7,
        alpha * 0.85,
      );
    }
  }

  void _drawPuff(
    Canvas canvas,
    Offset center,
    double radius,
    double alpha,
  ) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFB0BEC5).withValues(alpha: alpha),
            const Color(0xFFB0BEC5).withValues(alpha: 0.0),
          ],
        ).createShader(
            Rect.fromCircle(center: center, radius: radius)),
    );
  }

  // ---------- ДОЖДЬ ----------
  void _paintRain(Canvas canvas, double w, double h) {
    final math.Random rng = math.Random(101);
    const int drops = 42;

    for (int i = 0; i < drops; i++) {
      final double baseX = rng.nextDouble();
      final double baseY = rng.nextDouble();
      final double speedY = 0.7 + rng.nextDouble() * 0.6;
      final double len = h * (0.018 + rng.nextDouble() * 0.018);
      final double alpha = 0.22 + rng.nextDouble() * 0.20;

      final double yy = ((baseY + progress * speedY) % 1.0) * h * 0.65;
      final double xx = baseX * w;

      final Paint paint = Paint()
        ..color = const Color(0xFFB3E5FC).withValues(alpha: alpha)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(xx, yy),
        Offset(xx - 2.0, yy + len),
        paint,
      );
    }
  }

  // ---------- СНЕГ ----------
  void _paintSnowfall(Canvas canvas, double w, double h) {
    final math.Random rng = math.Random(404);

    // Мелкие
    for (int i = 0; i < 40; i++) {
      final double baseX = rng.nextDouble();
      final double baseY = rng.nextDouble();
      final double speedY = 0.08 + rng.nextDouble() * 0.32;
      final double sway = 0.02 + rng.nextDouble() * 0.05;
      final double r = 1.1 + rng.nextDouble() * 1.8;
      final double a = 0.40 + rng.nextDouble() * 0.30;

      final double yy = ((baseY + progress * speedY) % 1.0) * h * 0.68;
      final double xx =
          (baseX + math.sin(progress * 6.28 + i * 0.7) * sway) % 1.0 * w;

      canvas.drawCircle(
        Offset(xx, yy),
        r,
        Paint()..color = Colors.white.withValues(alpha: a),
      );
    }
    // Крупные в фокусе
    for (int i = 0; i < 8; i++) {
      final double baseX = rng.nextDouble();
      final double baseY = rng.nextDouble();
      final double speedY = 0.06 + rng.nextDouble() * 0.24;
      final double r = 2.4 + rng.nextDouble() * 1.6;
      final double a = 0.45 + rng.nextDouble() * 0.30;

      final double yy = ((baseY + progress * speedY) % 1.0) * h * 0.68;
      final double xx = baseX * w;

      canvas.drawCircle(
        Offset(xx, yy),
        r,
        Paint()..color = Colors.white.withValues(alpha: a),
      );
    }
  }

  // ---------- ГРОЗА ----------
  void _paintThunder(Canvas canvas, double w, double h) {
    final math.Random rng = math.Random(303);
    const int flashes = 3;

    for (int i = 0; i < flashes; i++) {
      // Вспышка активна в узком окне фазы
      final double phase = (progress + i / flashes) % 1.0;
      final double localPhase = (phase * 5) % 1.0;
      final double intensity = math.max(
        0.0,
        1.0 - (localPhase * 2.2),
      );
      if (intensity <= 0.02) continue;

      final double x = rng.nextDouble() * w * 0.7 + w * 0.15;
      final double y = h * (0.05 + rng.nextDouble() * 0.18);
      final double r = w * 0.06;

      canvas.drawCircle(
        Offset(x, y),
        r * 2.2,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFFFF59D)
                  .withValues(alpha: 0.55 * intensity),
              const Color(0xFFFFF59D).withValues(alpha: 0.0),
            ],
          ).createShader(
              Rect.fromCircle(center: Offset(x, y), radius: r * 2.2)),
      );
    }
  }

  // ---------- ТУМАН ----------
  void _paintFog(Canvas canvas, double w, double h) {
    const int bands = 6;

    for (int i = 0; i < bands; i++) {
      final double y = h * (0.22 + i * 0.09);
      final double bandH = h * 0.045;
      final double baseAlpha = 0.10 + (i % 2) * 0.05;

      // Лёгкое покачивание полос
      final double drift =
          math.sin(progress * 6.28 + i * 1.4) * w * 0.02;

      final Rect rect = Rect.fromLTWH(
        -w * 0.10 + drift,
        y,
        w * 1.20,
        bandH,
      );

      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              const Color(0xFFECEFF1).withValues(alpha: 0.0),
              const Color(0xFFECEFF1).withValues(alpha: baseAlpha),
              const Color(0xFFECEFF1).withValues(alpha: 0.0),
            ],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WeatherEffectsPainter old) =>
      old.effect != effect || old.progress != progress;
}

// ==================== СЕЗОННЫЙ ФОН ====================

class _SeasonalBackgroundPainter extends CustomPainter {
  final int season;
  final double progress;

  const _SeasonalBackgroundPainter({
    required this.season,
    this.progress = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (season == 0) return;

    final double w = size.width;
    final double h = size.height;

    late final List<Color> hillColors;
    late final List<double> baseYs;
    late final List<List<double>> peaksList;

    switch (season) {
      case 1:
        hillColors = [
          const Color(0xFFF8BBD0).withValues(alpha: 0.18),
          const Color(0xFFC5E1A5).withValues(alpha: 0.22),
          const Color(0xFFA5D6A7).withValues(alpha: 0.26),
          const Color(0xFF66BB6A).withValues(alpha: 0.30),
        ];
        baseYs = [0.55, 0.65, 0.75, 0.85];
        peaksList = [
          [0.20, 0.48, 0.55, 0.44, 0.82, 0.50],
          [0.14, 0.58, 0.46, 0.55, 0.76, 0.60],
          [0.26, 0.68, 0.60, 0.65, 0.86, 0.70],
          [0.10, 0.78, 0.42, 0.76, 0.72, 0.80],
        ];
        break;

      case 2:
        hillColors = [
          const Color(0xFFFFF59D).withValues(alpha: 0.18),
          const Color(0xFFDCE775).withValues(alpha: 0.22),
          const Color(0xFFAED581).withValues(alpha: 0.26),
          const Color(0xFF66BB6A).withValues(alpha: 0.30),
        ];
        baseYs = [0.55, 0.65, 0.75, 0.85];
        peaksList = [
          [0.22, 0.48, 0.58, 0.46, 0.84, 0.52],
          [0.16, 0.58, 0.48, 0.56, 0.78, 0.60],
          [0.24, 0.68, 0.62, 0.66, 0.88, 0.70],
          [0.12, 0.78, 0.44, 0.77, 0.74, 0.80],
        ];
        break;

      case 3:
        hillColors = [
          const Color(0xFFFFE0B2).withValues(alpha: 0.20),
          const Color(0xFFFFB74D).withValues(alpha: 0.25),
          const Color(0xFFFF8A65).withValues(alpha: 0.29),
          const Color(0xFF8D6E63).withValues(alpha: 0.32),
        ];
        baseYs = [0.55, 0.65, 0.75, 0.85];
        peaksList = [
          [0.18, 0.47, 0.52, 0.45, 0.80, 0.50],
          [0.14, 0.58, 0.44, 0.55, 0.74, 0.60],
          [0.22, 0.68, 0.58, 0.65, 0.84, 0.70],
          [0.10, 0.78, 0.40, 0.75, 0.70, 0.80],
        ];
        break;

      case 4:
        hillColors = [
          const Color(0xFFFFFFFF).withValues(alpha: 0.22),
          const Color(0xFFE1F5FE).withValues(alpha: 0.26),
          const Color(0xFFB3E5FC).withValues(alpha: 0.30),
          const Color(0xFF81D4FA).withValues(alpha: 0.34),
        ];
        baseYs = [0.55, 0.65, 0.75, 0.85];
        peaksList = [
          [0.20, 0.50, 0.56, 0.46, 0.82, 0.52],
          [0.16, 0.60, 0.48, 0.55, 0.78, 0.60],
          [0.24, 0.68, 0.62, 0.66, 0.86, 0.70],
          [0.12, 0.78, 0.44, 0.76, 0.72, 0.80],
        ];
        break;

      default:
        return;
    }

    for (int i = 0; i < hillColors.length; i++) {
      final Path path = _hillPath(size, baseYs[i], peaksList[i]);
      canvas.drawPath(path, Paint()..color = hillColors[i]);
    }

    _paintParticles(canvas, w, h);
  }

  Path _hillPath(Size size, double baseY, List<double> peaks) {
    final double w = size.width;
    final double h = size.height;
    final Path path = Path();

    path.moveTo(0, h);
    path.lineTo(0, h * baseY);

    double prevX = 0;
    for (int i = 0; i < peaks.length; i += 2) {
      final double px = peaks[i];
      final double py = peaks[i + 1];
      final double midX = (prevX + px) / 2.0;

      path.quadraticBezierTo(
        w * midX,
        h * baseY,
        w * px,
        h * py,
      );
      prevX = px;
    }

    final double lastMid = (prevX + 1.0) / 2.0;
    path.quadraticBezierTo(w * lastMid, h * baseY, w, h * baseY);
    path.lineTo(w, h);
    path.close();
    return path;
  }

  void _paintParticles(Canvas canvas, double w, double h) {
    final math.Random rng = math.Random(season * 7919);

    switch (season) {
      case 1:
        for (int i = 0; i < 34; i++) {
          final double baseX = rng.nextDouble();
          final double baseY = rng.nextDouble();
          final double speedY = 0.15 + rng.nextDouble() * 0.5;
          final double sway = 0.04 + rng.nextDouble() * 0.08;
          final double r = 2.0 + rng.nextDouble() * 2.0;
          final double a = 0.35 + rng.nextDouble() * 0.30;

          final double yy = ((baseY + progress * speedY) % 1.0) * h * 0.65;
          final double xx =
              (baseX + math.sin(progress * 6.28 + i) * sway) % 1.0 * w;

          canvas.drawCircle(
            Offset(xx, yy),
            r,
            Paint()..color = const Color(0xFFF8BBD0).withValues(alpha: a),
          );
          canvas.drawCircle(
            Offset(xx + r * 0.7, yy + r * 0.2),
            r * 0.7,
            Paint()
              ..color = const Color(0xFFFCE4EC).withValues(alpha: a * 0.8),
          );
        }
        break;

      case 2:
        final Offset sunCenter = Offset(w * 0.82, h * 0.14);
        canvas.drawCircle(
          sunCenter,
          w * 0.10,
          Paint()
            ..color = const Color(0xFFFFF59D).withValues(alpha: 0.28),
        );
        canvas.drawCircle(
          sunCenter,
          w * 0.06,
          Paint()
            ..color = const Color(0xFFFFF59D).withValues(alpha: 0.35),
        );

        for (int i = 0; i < 22; i++) {
          final double baseX = rng.nextDouble();
          final double baseY = rng.nextDouble();
          final double speedY = 0.10 + rng.nextDouble() * 0.35;
          final double r = 1.4 + rng.nextDouble() * 1.8;
          final double a = 0.30 + rng.nextDouble() * 0.30;

          final double yy = ((baseY + progress * speedY) % 1.0) * h * 0.65;
          final double xx = baseX * w;

          canvas.drawCircle(
            Offset(xx, yy),
            r,
            Paint()..color = const Color(0xFFFFF9C4).withValues(alpha: a),
          );
        }
        break;

      case 3:
        final List<Color> leafColors = [
          const Color(0xFFFFCC80),
          const Color(0xFFFFB74D),
          const Color(0xFFFF8A65),
          const Color(0xFFEF9A9A),
        ];
        for (int i = 0; i < 30; i++) {
          final double baseX = rng.nextDouble();
          final double baseY = rng.nextDouble();
          final double speedY = 0.20 + rng.nextDouble() * 0.55;
          final double sway = 0.05 + rng.nextDouble() * 0.10;
          final double sw = 4.0 + rng.nextDouble() * 3.0;
          final double sh = sw * 0.55;
          final double a = 0.35 + rng.nextDouble() * 0.30;
          final Color c = leafColors[rng.nextInt(leafColors.length)];

          final double yy = ((baseY + progress * speedY) % 1.0) * h * 0.68;
          final double xx =
              (baseX + math.sin(progress * 6.28 + i * 0.7) * sway) % 1.0 * w;

          canvas.save();
          canvas.translate(xx, yy);
          canvas.rotate(progress * 6.28 + i.toDouble());
          canvas.drawOval(
            Rect.fromCenter(center: Offset.zero, width: sw, height: sh),
            Paint()..color = c.withValues(alpha: a),
          );
          canvas.restore();
        }
        break;

      case 4:
        for (int i = 0; i < 44; i++) {
          final double baseX = rng.nextDouble();
          final double baseY = rng.nextDouble();
          final double speedY = 0.08 + rng.nextDouble() * 0.35;
          final double sway = 0.02 + rng.nextDouble() * 0.06;
          final double r = 1.1 + rng.nextDouble() * 2.0;
          final double a = 0.40 + rng.nextDouble() * 0.35;

          final double yy = ((baseY + progress * speedY) % 1.0) * h * 0.68;
          final double xx =
              (baseX + math.sin(progress * 6.28 + i * 0.5) * sway) % 1.0 * w;

          canvas.drawCircle(
            Offset(xx, yy),
            r,
            Paint()..color = Colors.white.withValues(alpha: a),
          );
        }
        for (int i = 0; i < 6; i++) {
          final double baseX = rng.nextDouble();
          final double baseY = rng.nextDouble();
          final double speedY = 0.06 + rng.nextDouble() * 0.25;
          final double r = 2.4 + rng.nextDouble() * 1.5;
          final double a = 0.45 + rng.nextDouble() * 0.30;

          final double yy = ((baseY + progress * speedY) % 1.0) * h * 0.68;
          final double xx = baseX * w;

          canvas.drawCircle(
            Offset(xx, yy),
            r,
            Paint()..color = Colors.white.withValues(alpha: a),
          );
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _SeasonalBackgroundPainter old) =>
      old.season != season || old.progress != progress;
}

// ==================== КАПЛЯ ВЛАЖНОСТИ ====================

class _DropletPainter extends CustomPainter {
  final double fillFraction;
  final Color baseColor;
  final Color fillColor;
  final Color outlineColor;

  _DropletPainter({
    required this.fillFraction,
    required this.baseColor,
    required this.fillColor,
    required this.outlineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = _buildDropletPath(size);

    canvas.drawPath(
      path,
      Paint()
        ..color = baseColor
        ..style = PaintingStyle.fill,
    );

    if (fillFraction > 0) {
      canvas.save();
      canvas.clipPath(path);
      final double h = size.height * fillFraction.clamp(0.0, 1.0);
      canvas.drawRect(
        Rect.fromLTWH(0, size.height - h, size.width, h),
        Paint()..color = fillColor,
      );
      canvas.restore();
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = outlineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  Path _buildDropletPath(Size size) {
    final double w = size.width;
    final double h = size.height;
    final Path path = Path();
    path.moveTo(w / 2, 0);
    path.cubicTo(w * 0.78, h * 0.22, w, h * 0.55, w, h * 0.72);
    path.cubicTo(w, h, 0, h, 0, h * 0.72);
    path.cubicTo(0, h * 0.55, w * 0.22, h * 0.22, w / 2, 0);
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _DropletPainter old) =>
      old.fillFraction != fillFraction ||
      old.baseColor != baseColor ||
      old.fillColor != fillColor ||
      old.outlineColor != outlineColor;
}