import 'package:dio/dio.dart';

import '../config/app_config.dart';

class AppRating {
  const AppRating({
    required this.id,
    required this.platform,
    required this.platformDisplay,
    required this.stars,
    required this.comment,
    required this.suggestion,
    required this.appVersion,
    required this.buildNumber,
    required this.deviceLabel,
    required this.usefulCount,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String platform;
  final String platformDisplay;
  final int stars;
  final String comment;
  final String suggestion;
  final String appVersion;
  final String buildNumber;
  final String deviceLabel;
  final int usefulCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory AppRating.fromJson(Map<String, dynamic> json) {
    return AppRating(
      id: int.tryParse(json['id']?.toString() ?? '') ?? 0,
      platform: json['platform']?.toString() ?? 'unknown',
      platformDisplay:
          json['platform_display']?.toString() ?? 'Unknown platform',
      stars: int.tryParse(json['stars']?.toString() ?? '') ?? 5,
      comment: json['comment']?.toString() ?? '',
      suggestion: json['suggestion']?.toString() ?? '',
      appVersion: json['app_version']?.toString() ?? '',
      buildNumber: json['build_number']?.toString() ?? '',
      deviceLabel: json['device_label']?.toString() ?? '',
      usefulCount: int.tryParse(json['useful_count']?.toString() ?? '') ?? 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

class AppRatingService {
  AppRatingService()
      : _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 20),
            headers: {'Content-Type': 'application/json'},
          ),
        );

  final Dio _dio;

  Future<AppRating?> fetchMyRating({required String reviewerKey}) async {
    final response = await _dio.get(
      AppConfig.myRatingApiUrl,
      queryParameters: {'reviewer_key': reviewerKey},
    );

    if (response.statusCode == 200 && response.data is Map) {
      final data = Map<String, dynamic>.from(response.data as Map);
      final rating = data['rating'];
      if (rating is Map) {
        return AppRating.fromJson(Map<String, dynamic>.from(rating));
      }
      return null;
    }

    throw StateError('Could not load app rating.');
  }

  Future<AppRating> submitRating({
    required String reviewerKey,
    required String platform,
    required int stars,
    required String comment,
    required String suggestion,
    required String appVersion,
    required String buildNumber,
    required String deviceLabel,
  }) async {
    final response = await _dio.post(
      AppConfig.ratingSubmitApiUrl,
      data: {
        'reviewer_key': reviewerKey,
        'platform': platform,
        'stars': stars,
        'comment': comment.trim(),
        'suggestion': suggestion.trim(),
        'app_version': appVersion.trim(),
        'build_number': buildNumber.trim(),
        'device_label': deviceLabel.trim(),
      },
    );

    if ((response.statusCode == 200 || response.statusCode == 201) &&
        response.data is Map) {
      final data = Map<String, dynamic>.from(response.data as Map);
      final rating = data['rating'];
      if (rating is Map) {
        return AppRating.fromJson(Map<String, dynamic>.from(rating));
      }
    }

    throw StateError('Could not submit app rating.');
  }
}
