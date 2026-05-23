// profile_service.dart

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http_parser/http_parser.dart';
import '../config/app_config.dart';
import 'secure_storage_service.dart';
import 'server_lockdown_service.dart';

class ProfileService {
  late Dio _dio;
  bool _isRefreshing = false;
  final SecureStorageService _secureStorage = SecureStorageService();

  ProfileService() {
    _dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.apiUrl, // Use config
        connectTimeout: Duration(seconds: 30),
        receiveTimeout: Duration(seconds: 30),
      ),
    );
    ServerLockdownService().attachDioInterceptor(
      _dio,
      featureSummary: 'load and edit your profile',
    );
  }

  Future<bool> _refreshToken() async {
    if (_isRefreshing) return false;

    _isRefreshing = true;
    final refreshToken = await _secureStorage.read(
      SecureStorageService.refreshTokenKey,
    );

    if (refreshToken == null) {
      _isRefreshing = false;
      return false;
    }

    try {
      debugPrint('Refreshing token for profile service...');
      final response = await _dio.post(
        'token/refresh/',
        data: {'refresh': refreshToken},
      );

      if (response.statusCode == 200) {
        final newAccessToken = response.data['access'];
        await _secureStorage.write(
          SecureStorageService.accessTokenKey,
          newAccessToken,
        );
        debugPrint('Token refreshed successfully for profile service');
        _isRefreshing = false;
        return true;
      }
      _isRefreshing = false;
      return false;
    } catch (e) {
      debugPrint('Token refresh failed: $e');
      _isRefreshing = false;
      return false;
    }
  }

  Future<Response> _requestWithRetry(
    Future<Response> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        debugPrint('Token expired in profile service, attempting refresh...');
        final refreshed = await _refreshToken();
        if (refreshed) {
          debugPrint('Retrying profile request with new token...');
          return await request();
        }
      }
      rethrow;
    }
  }

  Future<String?> _getToken() async {
    return _secureStorage.read(SecureStorageService.accessTokenKey);
  }

  Future<Map<String, dynamic>?> getProfile() async {
    final token = await _getToken();
    if (token == null) {
      debugPrint('No token available for profile request');
      return null;
    }

    try {
      debugPrint('Making profile request...');
      final response = await _requestWithRetry(
        () => _dio.get(
          'profile/my_profile/',
          options: Options(
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          ),
        ),
      );

      debugPrint('Profile response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        return response.data;
      }
      return null;
    } catch (e) {
      debugPrint('Error getting profile: $e');
      return null;
    }
  }

  Future<bool> updateProfilePhoto(File imageFile) async {
    final token = await _getToken();
    if (token == null) {
      debugPrint('No token available for photo upload');
      return false;
    }

    try {
      String fileName = imageFile.path.split('/').last;

      FormData formData = FormData.fromMap({
        'profile_photo': await MultipartFile.fromFile(
          imageFile.path,
          filename: fileName,
          contentType: MediaType('image', 'jpeg'),
        ),
      });

      debugPrint('Uploading photo...');
      final response = await _requestWithRetry(
        () => _dio.post(
          'profile/update_profile/',
          data: formData,
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        ),
      );

      debugPrint('Upload response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        debugPrint('Photo uploaded successfully');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error uploading photo: $e');
      return false;
    }
  }

  Future<bool> updateBio(String bio) async {
    final token = await _getToken();
    if (token == null) {
      debugPrint('No token available for bio update');
      return false;
    }

    try {
      debugPrint('Updating bio...');
      final response = await _requestWithRetry(
        () => _dio.post(
          'profile/update_profile/',
          data: {'bio': bio},
          options: Options(
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          ),
        ),
      );

      debugPrint('Bio update response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        debugPrint('Bio updated successfully');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error updating bio: $e');
      return false;
    }
  }
}
