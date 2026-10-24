import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/pet_models.dart';

class GpsWeatherData {
  final double? lat;
  final double? lon;
  final String locationName;
  final double tempC;
  final String weatherCondition;
  final String weatherSummary;

  GpsWeatherData({
    required this.lat,
    required this.lon,
    required this.locationName,
    required this.tempC,
    required this.weatherCondition,
    required this.weatherSummary,
  });
}

class DeviceAndMusicService {
  static const MethodChannel _channel =
      MethodChannel('id.xiaozhi.aipet/device');

  // Kunci pengaman agar setelah di-stop, AI tidak bisa memutar lagu hantu sendiri
  static DateTime _musicStopLockUntil = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get isMusicStartLocked =>
      DateTime.now().isBefore(_musicStopLockUntil);

  // =======================================================================
  // 1. KONTROL MUSIK YOUTUBE (ANTI-BOCOR & DUKUNGAN INTERUPSI SUARA)
  // =======================================================================
  static Future<bool> playYoutube(String query,
      {bool bypassLock = false}) async {
    if (!bypassLock && isMusicStartLocked) {
      return false;
    }
    try {
      await _channel.invokeMethod('playYoutube', {'query': query});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Menghentikan total WebView YouTube dan mengunci pemutaran ulang liar selama 6 detik
  static Future<void> hardStopYoutube() async {
    _musicStopLockUntil = DateTime.now().add(const Duration(seconds: 6));
    try {
      await _channel.invokeMethod('stopYoutube');
    } catch (_) {}
  }

  /// Menjeda/mengecilkan musik YouTube saat pengguna sedang bicara (Interupsi Suara)
  static Future<void> setYoutubeInterrupted(bool interrupted) async {
    try {
      await _channel.invokeMethod('duckYoutube', {'duck': interrupted});
    } catch (_) {}
  }

  static Future<int> getVolume() async {
    try {
      return (await _channel.invokeMethod('getVolume')) as int? ?? 80;
    } catch (_) {
      return 80;
    }
  }

  static Future<void> setVolume(int volume) async {
    try {
      await _channel.invokeMethod('setVolume', {'volume': volume});
    } catch (_) {}
  }

  static MusicianMode detectMusicianStyle(String text,
      {String? explicitStyle}) {
    final raw = "${explicitStyle ?? ''} $text".toLowerCase();
    if (raw.contains('gitar') ||
        raw.contains('guitar') ||
        raw.contains('rock') ||
        raw.contains('metal') ||
        raw.contains('band')) {
      return MusicianMode.guitar;
    }
    if (raw.contains('piano') ||
        raw.contains('keyboard') ||
        raw.contains('klasik') ||
        raw.contains('classic') ||
        raw.contains('jazz') ||
        raw.contains('ballad')) {
      return MusicianMode.piano;
    }
    if (raw.contains('vokal') ||
        raw.contains('vocal') ||
        raw.contains('nyanyi') ||
        raw.contains('sing') ||
        raw.contains('karaoke')) {
      return MusicianMode.vocal;
    }
    if (raw.contains('dj') ||
        raw.contains('remix') ||
        raw.contains('jedag') ||
        raw.contains('edm') ||
        raw.contains('bass') ||
        raw.contains('disco')) {
      return MusicianMode.dj;
    }
    const styles = [
      MusicianMode.dj,
      MusicianMode.guitar,
      MusicianMode.piano,
      MusicianMode.vocal,
    ];
    return styles[Random().nextInt(styles.length)];
  }

  // =======================================================================
  // 2. DETEKSI WAKTU LOKAL INDONESIA (SUBUH / PAGI / SIANG / SORE / MALAM)
  // =======================================================================
  static String computeIndonesianTimePhase(DateTime now) {
    final int totalMinutes = now.hour * 60 + now.minute;
    if (totalMinutes >= 180 && totalMinutes <= 330) {
      return "Waktu Subuh / Dini Hari"; // 03:00 - 05:30
    } else if (totalMinutes > 330 && totalMinutes < 660) {
      return "Waktu Pagi"; // 05:31 - 10:59
    } else if (totalMinutes >= 660 && totalMinutes < 900) {
      return "Waktu Siang"; // 11:00 - 14:59
    } else if (totalMinutes >= 900 && totalMinutes <= 1080) {
      return "Waktu Sore"; // 15:00 - 18:00
    } else {
      return "Waktu Malam"; // 18:01 - 02:59
    }
  }

  // =======================================================================
  // 3. LOKASI HARDWARE GPS & CUACA REAL-TIME
  // =======================================================================
  static Future<GpsWeatherData> fetchGpsAndWeather({
    double? currentLat,
    double? currentLon,
    String currentLocationName = "Mencari GPS...",
    double currentTemp = 28.0,
    String currentCondition = "Cerah",
  }) async {
    double? lat = currentLat;
    double? lon = currentLon;
    String locName = currentLocationName;
    double temp = currentTemp;
    String cond = currentCondition;

    try {
      final dynamic gpsMap = await _channel.invokeMethod('getGpsLocation');
      if (gpsMap != null && gpsMap is Map) {
        lat = (gpsMap['lat'] as num?)?.toDouble() ?? lat;
        lon = (gpsMap['lon'] as num?)?.toDouble() ?? lon;
      }

      if (lat == null || lon == null) {
        final ipRes = await http
            .get(Uri.parse(
                "https://api.bigdatacloud.net/data/reverse-geocode-client?localityLanguage=id"))
            .timeout(const Duration(seconds: 6));
        if (ipRes.statusCode == 200) {
          final d = jsonDecode(ipRes.body);
          lat = (d['latitude'] as num?)?.toDouble();
          lon = (d['longitude'] as num?)?.toDouble();
        }
      }

      if (lat != null && lon != null) {
        final revUrl =
            "https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=$lat&longitude=$lon&localityLanguage=id";
        final revRes = await http
            .get(Uri.parse(revUrl))
            .timeout(const Duration(seconds: 6));
        if (revRes.statusCode == 200) {
          final rev = jsonDecode(utf8.decode(revRes.bodyBytes));
          final locality = rev['locality']?.toString() ?? "";
          final city = rev['city']?.toString() ??
              rev['principalSubdivision']?.toString() ??
              "";
          if (locality.isNotEmpty && city.isNotEmpty && locality != city) {
            locName = "$locality, $city";
          } else if (locality.isNotEmpty) {
            locName = locality;
          } else if (city.isNotEmpty) {
            locName = city;
          }
        }

        final wRes = await http
            .get(Uri.parse(
                "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current_weather=true"))
            .timeout(const Duration(seconds: 6));
        if (wRes.statusCode == 200) {
          final w = jsonDecode(wRes.body)['current_weather'];
          temp = (w['temperature'] as num?)?.toDouble() ?? 28.0;
          final wCode = (w['weathercode'] as num?)?.toInt() ?? 0;
          cond = _decodeWeatherCode(wCode);
        }
      }

      return GpsWeatherData(
        lat: lat,
        lon: lon,
        locationName: locName,
        tempC: temp,
        weatherCondition: cond,
        weatherSummary: "$temp°C • $locName",
      );
    } catch (_) {
      return GpsWeatherData(
        lat: lat,
        lon: lon,
        locationName: locName,
        tempC: temp,
        weatherCondition: cond,
        weatherSummary: "GPS Aktif • Online",
      );
    }
  }

  static String _decodeWeatherCode(int code) {
    if (code == 0) return "Cerah";
    if (code <= 3) return "Berawan";
    if (code <= 48) return "Berkabut";
    if (code <= 67) return "Hujan Ringan";
    if (code <= 82) return "Hujan Deras";
    if (code >= 95) return "Badai Petir";
    return "Cerah Berawan";
  }
}
