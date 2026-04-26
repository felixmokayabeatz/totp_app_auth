import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/app_update_info.dart';

class AppUpdateService {
  static final AppUpdateService _instance = AppUpdateService._internal();
  factory AppUpdateService() => _instance;

  AppUpdateService._internal()
      : _dio = Dio(
          BaseOptions(
            baseUrl: AppConfig.updateApiUrl,
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 20),
            headers: {'Content-Type': 'application/json'},
          ),
        );

  final Dio _dio;
  AppUpdateInfo? _cachedUpdateInfo;

  AppUpdateInfo? get cachedUpdateInfo => _cachedUpdateInfo;

  String get currentPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return '';
  }

  Future<AppUpdateInfo?> checkForUpdate() async {
    final platform = currentPlatform;
    if (platform.isEmpty) {
      return null;
    }

    final packageInfo = await PackageInfo.fromPlatform();
    final version = packageInfo.version.trim();
    final buildNumber = int.tryParse(packageInfo.buildNumber.trim()) ?? 0;

    try {
      final response = await _dio.get(
        '',
        queryParameters: {
          'platform': platform,
          'version': version,
          'build_number': buildNumber,
        },
      );

      if (response.statusCode == 200 && response.data is Map) {
        _cachedUpdateInfo = AppUpdateInfo.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        return _cachedUpdateInfo;
      }
    } catch (_) {
      return _cachedUpdateInfo;
    }

    return _cachedUpdateInfo;
  }

  Future<String> getCurrentVersionLabel() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final version = packageInfo.version.trim();
    final buildNumber = packageInfo.buildNumber.trim();
    return buildNumber.isEmpty ? version : '$version (Build $buildNumber)';
  }

  Future<bool> openUpdate(AppUpdateInfo info) async {
    if (!info.canDownload) return false;

    final uri = Uri.tryParse(info.preferredOpenUrl);
    if (uri == null) return false;

    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
