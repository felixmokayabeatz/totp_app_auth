class AppConfig {
  // Development environment
  static const String devApiUrl = 'http://localhost:8000/api/';
  static const String devMediaUrl = 'http://localhost:8000/media/';
  
  // Production environment (your VPS)
  static const String prodApiUrl = 'http://153.75.224.243/api/';
  static const String prodMediaUrl = 'http://153.75.224.243/media/';
  
  // Change this to false when building for production
  static const bool isDevelopment = true;
  
  static String get apiUrl {
    return isDevelopment ? devApiUrl : prodApiUrl;
  }
  
  static String get mediaUrl {
    return isDevelopment ? devMediaUrl : prodMediaUrl;
  }
}