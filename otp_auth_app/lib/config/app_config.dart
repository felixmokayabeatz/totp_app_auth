// app_config.dart

import 'dart:io' show Platform;

class AppConfig {
  // Development environment
  static const String devApiUrlDesktop = 'http://localhost:8000/api/';
  static const String devMediaUrlDesktop = 'http://localhost:8000/media/';
  static const String devUpdateApiDesktop =
      'http://localhost:8000/beatzlock-apps/api/update-check/';

  // For Android emulator - 10.0.2.2 is alias for host machine's localhost
  static const String devApiUrlAndroid = 'http://10.0.2.2:8000/api/';
  static const String devMediaUrlAndroid = 'http://10.0.2.2:8000/media/';
  static const String devUpdateApiAndroid =
      'http://10.0.2.2:8000/beatzlock-apps/api/update-check/';

  // Production environment (your VPS)
  static const String prodApiUrl = 'https://api.felixmokayabeatz.online/api/';
  static const String prodMediaUrl =
      'https://api.felixmokayabeatz.online/media/';
  static const String prodUpdateApiUrl =
      'https://felixmokayabeatz.online/beatzlock-apps/api/update-check/';

  // Change this to false when building for production
  static const bool isDevelopment = false;

  static String get apiUrl {
    if (!isDevelopment) return prodApiUrl;

    // Check if running on Android
    if (Platform.isAndroid) {
      return devApiUrlAndroid;
    }
    return devApiUrlDesktop;
  }

  static String get mediaUrl {
    if (!isDevelopment) return prodMediaUrl;

    // Check if running on Android
    if (Platform.isAndroid) {
      return devMediaUrlAndroid;
    }
    return devMediaUrlDesktop;
  }

  static String get updateApiUrl {
    if (!isDevelopment) return prodUpdateApiUrl;

    if (Platform.isAndroid) {
      return devUpdateApiAndroid;
    }
    return devUpdateApiDesktop;
  }
}
