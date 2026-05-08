import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
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
  String? _lastErrorMessage;

  AppUpdateInfo? get cachedUpdateInfo => _cachedUpdateInfo;
  String? get lastErrorMessage => _lastErrorMessage;
  bool get canSelfUpdate => Platform.isWindows || Platform.isLinux;

  String get currentPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    return '';
  }

  Future<AppUpdateInfo?> checkForUpdate() async {
    final platform = currentPlatform;
    _lastErrorMessage = null;
    if (platform.isEmpty) {
      _lastErrorMessage = 'Updates are not available for this platform.';
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
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyUpdateError(e);
      return _cachedUpdateInfo;
    } catch (_) {
      _lastErrorMessage = 'Could not check for updates right now.';
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

  Future<AppSelfUpdateResult> installUpdate(
    AppUpdateInfo info, {
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    if (!canSelfUpdate) {
      return const AppSelfUpdateResult(
        started: false,
        message: 'Self-update is not supported on this platform.',
      );
    }

    final downloadUri = Uri.tryParse(info.downloadUrl.trim());
    if (downloadUri == null) {
      return const AppSelfUpdateResult(
        started: false,
        message: 'The update download is not available yet.',
      );
    }

    try {
      final installerPath = await _downloadInstaller(
        info,
        downloadUri,
        onReceiveProgress: onReceiveProgress,
      );
      await _launchInstaller(installerPath);
      return const AppSelfUpdateResult(
        started: true,
        message:
            'Updater started. BeatzLock may close and reopen when installation finishes.',
      );
    } on DioException catch (e) {
      return AppSelfUpdateResult(
        started: false,
        message: _friendlyUpdateError(e),
      );
    } catch (e) {
      return AppSelfUpdateResult(
        started: false,
        message: 'Could not start the self-updater: $e',
      );
    }
  }

  Future<String> _downloadInstaller(
    AppUpdateInfo info,
    Uri downloadUri, {
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final updateDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}beatzlock_updates',
    );
    if (!await updateDir.exists()) {
      await updateDir.create(recursive: true);
    }

    final extension = _installerExtension(downloadUri);
    final fileName =
        'beatzlock_${info.latestVersion}_${info.latestBuildNumber}$extension';
    final filePath = '${updateDir.path}${Platform.pathSeparator}$fileName';

    await _dio.download(
      downloadUri.toString(),
      filePath,
      onReceiveProgress: onReceiveProgress,
      options: Options(
        followRedirects: true,
        responseType: ResponseType.bytes,
      ),
    );

    return filePath;
  }

  String _installerExtension(Uri uri) {
    final lastSegment =
        uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.toLowerCase();
    if (lastSegment.endsWith('.exe')) return '.exe';
    if (lastSegment.endsWith('.deb')) return '.deb';
    if (lastSegment.endsWith('.rpm')) return '.rpm';
    if (Platform.isWindows) return '.exe';
    return '.deb';
  }

  Future<void> _launchInstaller(String installerPath) async {
    if (Platform.isWindows) {
      await Process.start(
        installerPath,
        const [
          '/SP-',
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
          '/RESTARTAPPLICATIONS',
        ],
        mode: ProcessStartMode.detached,
      );
      return;
    }

    if (Platform.isLinux) {
      final scriptPath = await _writeLinuxUpdaterScript(installerPath);
      await Process.start(
        'sh',
        [scriptPath],
        mode: ProcessStartMode.detached,
      );
    }
  }

  Future<String> _writeLinuxUpdaterScript(String installerPath) async {
    final tempDir = await getTemporaryDirectory();
    final script = File(
      '${tempDir.path}${Platform.pathSeparator}beatzlock_update.sh',
    );
    final escapedInstallerPath = installerPath.replaceAll("'", r"'\''");
    await script.writeAsString('''
#!/bin/sh
set -eu
DEB_PATH='$escapedInstallerPath'
APP_PATH="/usr/local/BeatzLock/otp_auth_app"

if command -v pkexec >/dev/null 2>&1; then
  pkexec sh -c 'dpkg -i "\$1" || apt-get install -f -y' sh "\$DEB_PATH"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "\$DEB_PATH"
  exit 0
else
  exit 1
fi

if [ -x "\$APP_PATH" ]; then
  nohup "\$APP_PATH" >/dev/null 2>&1 &
fi
''');

    await Process.run('chmod', ['700', script.path]);
    return script.path;
  }

  String _friendlyUpdateError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return 'No internet connection. Connect to the internet and try again.';
      case DioExceptionType.badCertificate:
        return 'Secure update connection failed. Check this device date and certificate trust.';
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        if (statusCode == 404) {
          return 'The update file was not found on the server.';
        }
        if (statusCode != null && statusCode >= 500) {
          return 'The update server is unavailable right now.';
        }
        return 'Could not check for updates right now.';
      case DioExceptionType.cancel:
        return 'Update check was cancelled.';
    }
  }
}

class AppSelfUpdateResult {
  const AppSelfUpdateResult({
    required this.started,
    required this.message,
  });

  final bool started;
  final String message;
}
