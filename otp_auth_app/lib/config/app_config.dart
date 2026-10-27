

import 'dart:io' show Platform;

class AppConfig {

  static const String devApiUrlDesktop = 'http://localhost:8000/api/';
  static const String devMediaUrlDesktop = 'http://localhost:8000/media/';



  static const String devBeatzLockAppsBaseDesktop = 'http://localhost:8005/';
  static const String devUpdateApiDesktop =
      '${devBeatzLockAppsBaseDesktop}api/update-check/';


  static const String devApiUrlAndroid = 'http://10.0.2.2:8000/api/';
  static const String devMediaUrlAndroid = 'http://10.0.2.2:8000/media/';
  static const String devBeatzLockAppsBaseAndroid = 'http://10.0.2.2:8005/';
  static const String devUpdateApiAndroid =
      '${devBeatzLockAppsBaseAndroid}api/update-check/';


  static const String prodApiUrl = 'https://api.example.com/api/';
  static const String prodMediaUrl = 'https://api.example.com/media/';



  static const String prodBeatzLockAppsBaseUrl =
      'https://apps.example.com/';
  static const String prodUpdateApiUrl =
      '${prodBeatzLockAppsBaseUrl}api/update-check/';
  static const String creatorWebsiteUrl = 'https://example.com/';
  static const String creatorGithubUrl = 'https://github.com/felixmokayabeatz/';



  static const bool isDevelopment = false;




  static String get apiUrl {
    if (!isDevelopment) return prodApiUrl;


    if (Platform.isAndroid) {
      return devApiUrlAndroid;
    }
    return devApiUrlDesktop;
  }

  static String get mediaUrl {
    if (!isDevelopment) return prodMediaUrl;


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

  static String get beatzLockAppsBaseUrl {
    if (!isDevelopment) return prodBeatzLockAppsBaseUrl;

    if (Platform.isAndroid) {
      return devBeatzLockAppsBaseAndroid;
    }
    return devBeatzLockAppsBaseDesktop;
  }

  static String legalDocumentApiUrl(String type) =>
      '${beatzLockAppsBaseUrl}api/legal/$type/';

  static String legalDocumentWebUrl(String type) {
    final slug = type == 'terms' ? 'terms-of-service' : 'privacy-policy';
    return '${beatzLockAppsBaseUrl}legal/$slug/';
  }

  static String get ratingSubmitApiUrl =>
      '${beatzLockAppsBaseUrl}api/ratings/submit/';

  static String get ratingDeleteApiUrl =>
      '${beatzLockAppsBaseUrl}api/ratings/delete/';

  static String get ratingsApiUrl => '${beatzLockAppsBaseUrl}api/ratings/';

  static String get myRatingApiUrl => '${beatzLockAppsBaseUrl}api/ratings/me/';

  static String get rateAppUrl => '${beatzLockAppsBaseUrl}rate/';

  static String get manualDownloadUrl => '${beatzLockAppsBaseUrl}downloads/';
}
