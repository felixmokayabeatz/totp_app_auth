import 'dart:io' show Platform;

class AppConfig {
  // Development environment
  static const String devApiUrlDesktop = 'http://localhost:8000/api/';
  static const String devMediaUrlDesktop = 'http://localhost:8000/media/';

  // For Android emulator - 10.0.2.2 is alias for host machine's localhost
  static const String devApiUrlAndroid = 'http://10.0.2.2:8000/api/';
  static const String devMediaUrlAndroid = 'http://10.0.2.2:8000/media/';

  // Production environment (your VPS)
  static const String prodApiUrl = 'https://api.felixmokayabeatz.online/api/';
  static const String prodMediaUrl =
      'https://api.felixmokayabeatz.online/media/';

  // Change this to false when building for production
  static const bool isDevelopment = true;

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
}
