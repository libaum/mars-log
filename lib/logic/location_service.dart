import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

/// Where an entry was recorded: coordinates plus a human-readable label.
class EntryLocation {
  final double latitude;
  final double longitude;
  final String? place;
  EntryLocation(this.latitude, this.longitude, this.place);
}

/// Best-effort location lookup for new entries. Every call is optional and
/// silent — it returns null on any failure (permission denied, services off,
/// timeout, offline) and never throws, so it can't break entry creation.
class LocationService {
  Future<EntryLocation?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      // Prefer an instant last-known fix; fall back to a fresh, bounded one.
      var position = await Geolocator.getLastKnownPosition();
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 8),
        ),
      );

      final label = await _label(position.latitude, position.longitude);
      return EntryLocation(position.latitude, position.longitude, label);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _label(double lat, double lng) async {
    try {
      final marks = await placemarkFromCoordinates(lat, lng);
      if (marks.isEmpty) return null;
      final m = marks.first;
      final parts = <String?>[m.locality, m.subLocality]
          .where((s) => s != null && s.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) return parts.join(', ');
      final fallback = <String?>[m.administrativeArea, m.country]
          .where((s) => s != null && s.isNotEmpty)
          .toList();
      return fallback.isEmpty ? null : fallback.join(', ');
    } catch (_) {
      return null;
    }
  }
}
