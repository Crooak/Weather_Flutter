import 'package:geolocator/geolocator.dart';

enum LocationStatus {
  success,
  serviceDisabled,
  permissionDenied,
  timeout,
}

class LocationResult {
  final double? latitude;
  final double? longitude;
  final LocationStatus status;

  const LocationResult({
    required this.latitude,
    required this.longitude,
    required this.status,
  });

  bool get hasPosition => latitude != null && longitude != null;
}

class LocationService {
  Future<LocationResult> getCurrentLocation() async {
    try {
      // 1. Служба геолокации включена?
      final bool serviceEnabled =
          await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const LocationResult(
          latitude: null,
          longitude: null,
          status: LocationStatus.serviceDisabled,
        );
      }

      // 2. Разрешения
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return const LocationResult(
          latitude: null,
          longitude: null,
          status: LocationStatus.permissionDenied,
        );
      }

      // 3. Последнее известное — как fallback
      Position? lastKnown;
      try {
        lastKnown = await Geolocator.getLastKnownPosition();
        final DateTime? ts = lastKnown?.timestamp;
        if (ts != null && DateTime.now().difference(ts).inMinutes > 30) {
          lastKnown = null;
        }
      } catch (_) {
        lastKnown = null;
      }

      // 4. Актуальная позиция, 15 секунд — с запасом на прогрев GPS
      try {
        final Position position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 15),
          ),
        );
        return LocationResult(
          latitude: position.latitude,
          longitude: position.longitude,
          status: LocationStatus.success,
        );
      } catch (_) {
        if (lastKnown != null) {
          return LocationResult(
            latitude: lastKnown.latitude,
            longitude: lastKnown.longitude,
            status: LocationStatus.success,
          );
        }
        return const LocationResult(
          latitude: null,
          longitude: null,
          status: LocationStatus.timeout,
        );
      }
    } catch (_) {
      return const LocationResult(
        latitude: null,
        longitude: null,
        status: LocationStatus.timeout,
      );
    }
  }
}