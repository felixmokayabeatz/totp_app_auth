import 'package:dio/dio.dart';

import '../config/app_config.dart';

class AppRating {
  const AppRating({
    required this.id,
    required this.platform,
    required this.platformDisplay,
    required this.displayName,
    required this.stars,
    required this.comment,
    required this.suggestion,
    required this.appVersion,
    required this.buildNumber,
    required this.deviceLabel,
    required this.usefulCount,
    required this.adminReply,
    required this.createdAt,
    required this.updatedAt,
    required this.adminRepliedAt,
  });

  final int id;
  final String platform;
  final String platformDisplay;
  final String displayName;
  final int stars;
  final String comment;
  final String suggestion;
  final String appVersion;
  final String buildNumber;
  final String deviceLabel;
  final int usefulCount;
  final String adminReply;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? adminRepliedAt;

  factory AppRating.fromJson(Map<String, dynamic> json) {
    return AppRating(
      id: int.tryParse(json['id']?.toString() ?? '') ?? 0,
      platform: json['platform']?.toString() ?? 'unknown',
      platformDisplay:
          json['platform_display']?.toString() ?? 'Unknown platform',
      displayName: json['display_name']?.toString() ??
          json['display_name_or_anonymous']?.toString() ??
          'Anonymous user',
      stars: int.tryParse(json['stars']?.toString() ?? '') ?? 5,
      comment: json['comment']?.toString() ?? '',
      suggestion: json['suggestion']?.toString() ?? '',
      appVersion: json['app_version']?.toString() ?? '',
      buildNumber: json['build_number']?.toString() ?? '',
      deviceLabel: json['device_label']?.toString() ?? '',
      usefulCount: int.tryParse(json['useful_count']?.toString() ?? '') ?? 0,
      adminReply: json['admin_reply']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      adminRepliedAt: DateTime.tryParse(
        json['admin_replied_at']?.toString() ?? '',
      ),
    );
  }
}

class AppRatingSummary {
  const AppRatingSummary({required this.average, required this.count});

  final double average;
  final int count;

  factory AppRatingSummary.fromJson(Map<String, dynamic> json) {
    return AppRatingSummary(
      average: double.tryParse(json['average']?.toString() ?? '') ?? 0,
      count: int.tryParse(json['count']?.toString() ?? '') ?? 0,
    );
  }
}

class AppRatingLookup {
  const AppRatingLookup({required this.rating, required this.displayName});

  final AppRating? rating;
  final String displayName;
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

  Future<AppRatingLookup> fetchMyRating({
    required String reviewerKey,
    required String platform,
  }) async {
    final response = await _dio.get(
      AppConfig.myRatingApiUrl,
      queryParameters: {'reviewer_key': reviewerKey, 'platform': platform},
    );

    if (response.statusCode == 200 && response.data is Map) {
      final data = Map<String, dynamic>.from(response.data as Map);
      final rating = data['rating'];
      final displayName = data['display_name']?.toString() ?? '';
      if (rating is Map) {
        return AppRatingLookup(
          rating: AppRating.fromJson(Map<String, dynamic>.from(rating)),
          displayName: displayName,
        );
      }
      return AppRatingLookup(rating: null, displayName: displayName);
    }

    throw StateError('Could not load app rating.');
  }

  Future<AppRatingSummary> fetchPlatformSummary({
    required String platform,
  }) async {
    final response = await _dio.get(
      AppConfig.ratingsApiUrl,
      queryParameters: {'platform': platform},
    );

    if (response.statusCode == 200 && response.data is Map) {
      final data = Map<String, dynamic>.from(response.data as Map);
      final summary = data['summary'];
      if (summary is Map) {
        return AppRatingSummary.fromJson(Map<String, dynamic>.from(summary));
      }
    }

    throw StateError('Could not load platform rating summary.');
  }

  Future<AppRating> submitRating({
    required String reviewerKey,
    required String platform,
    required String displayName,
    required int stars,
    required String comment,
    required String suggestion,
    required String appVersion,
    required String buildNumber,
    required String deviceLabel,
    required String accountUserId,
    required String accountEmail,
    required String accountUsername,
  }) async {
    final response = await _dio.post(
      AppConfig.ratingSubmitApiUrl,
      data: {
        'reviewer_key': reviewerKey,
        'platform': platform,
        'display_name': displayName.trim(),
        'stars': stars,
        'comment': comment.trim(),
        'suggestion': suggestion.trim(),
        'app_version': appVersion.trim(),
        'build_number': buildNumber.trim(),
        'device_label': deviceLabel.trim(),
        'account_user_id': accountUserId.trim(),
        'account_email': accountEmail.trim(),
        'account_username': accountUsername.trim(),
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

  Future<bool> deleteRating({
    required String reviewerKey,
    required String platform,
  }) async {
    final response = await _dio.post(
      AppConfig.ratingDeleteApiUrl,
      data: {'reviewer_key': reviewerKey, 'platform': platform},
    );

    if (response.statusCode == 200 && response.data is Map) {
      final data = Map<String, dynamic>.from(response.data as Map);
      return data['deleted'] == true || data['platform_deleted'] == true;
    }

    throw StateError('Could not delete app rating.');
  }
}
