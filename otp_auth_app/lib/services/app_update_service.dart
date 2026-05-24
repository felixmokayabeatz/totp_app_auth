import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../config/app_build_info.dart';
import '../models/app_update_info.dart';
import 'server_lockdown_service.dart';

class AppUpdateService {
  static final AppUpdateService _instance = AppUpdateService._internal();
  static const MethodChannel _storageChannel = MethodChannel(
    'com.beatzlock.otp/storage',
  );
  static const String updateInstalledArgumentPrefix = '--update-installed=';
  static const Map<String, String> _linuxDistributionAliases = {
    'ubuntu': 'ubuntu',
    'debian': 'debian',
    'kali': 'kali',
    'kalilinux': 'kali',
    'fedora': 'fedora',
    'rhel': 'fedora',
    'redhat': 'fedora',
    'redhatenterpriselinux': 'fedora',
    'centos': 'fedora',
    'rocky': 'fedora',
    'rockylinux': 'fedora',
    'almalinux': 'fedora',
    'opensuse': 'opensuse',
    'opensuseleap': 'opensuse',
    'opensusetumbleweed': 'opensuse',
    'suse': 'opensuse',
    'arch': 'arch',
    'archlinux': 'arch',
    'manjaro': 'manjaro',
  };
  factory AppUpdateService() => _instance;

  AppUpdateService._internal()
      : _dio = Dio(
          BaseOptions(
            baseUrl: AppConfig.updateApiUrl,
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 20),
            headers: {'Content-Type': 'application/json'},
          ),
        ) {
    ServerLockdownService().attachDioInterceptor(
      _dio,
      featureSummary: 'check for app updates and release notes',
    );
  }

  final Dio _dio;
  AppUpdateInfo? _cachedUpdateInfo;
  String? _lastErrorMessage;
  CancelToken? _activeDownloadCancelToken;
  String? _pendingLauncherExecutable;
  List<String>? _pendingLauncherArguments;
  final List<String> _pendingCleanupPaths = <String>[];

  AppUpdateInfo? get cachedUpdateInfo => _cachedUpdateInfo;
  String? get lastErrorMessage => _lastErrorMessage;
  bool get canSelfUpdate => Platform.isWindows || Platform.isLinux;
  bool get canDownloadUpdateInApp =>
      Platform.isWindows || Platform.isLinux || Platform.isAndroid;

  Future<_CurrentAppVersion> _resolveCurrentAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version.trim();
      final buildNumber = packageInfo.buildNumber.trim();
      if (version.isNotEmpty) {
        return _CurrentAppVersion(
          version: version,
          buildNumber:
              buildNumber.isEmpty ? AppBuildInfo.buildNumber : buildNumber,
        );
      }
    } catch (_) {
      // Fall through to the bundled fallback below.
    }

    return const _CurrentAppVersion(
      version: AppBuildInfo.version,
      buildNumber: AppBuildInfo.buildNumber,
    );
  }

  String get currentPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    return '';
  }

  bool get isUpdateDownloadInProgress => _activeDownloadCancelToken != null;

  void cancelUpdateDownload() {
    _activeDownloadCancelToken?.cancel('User cancelled update download.');
  }

  void clearPreparedUpdate() {
    _clearPreparedUpdateState(cleanupArtifacts: true);
  }

  Future<void> cleanupStaleUpdateArtifacts() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final separator = Platform.pathSeparator;
      await _deletePaths(<String>[
        '${tempDir.path}${separator}beatzlock_updates',
        '${tempDir.path}${separator}beatzlock_update.sh',
      ]);
    } catch (_) {
      // Temporary update cleanup is best-effort only.
    }
  }

  Future<AppUpdateInfo?> checkForUpdate() async {
    final platform = currentPlatform;
    _lastErrorMessage = null;
    if (platform.isEmpty) {
      _lastErrorMessage = 'Updates are not available for this platform.';
      return null;
    }

    try {
      final currentAppVersion = await _resolveCurrentAppVersion();
      final queryParameters = <String, dynamic>{
        'platform': platform,
        'version': currentAppVersion.version,
        'build_number': currentAppVersion.parsedBuildNumber,
      };
      final linuxDistribution = await _resolveLinuxDistribution();
      if (linuxDistribution != null && linuxDistribution.isNotEmpty) {
        queryParameters['distribution'] = linuxDistribution;
      }

      final response = await _dio.get('', queryParameters: queryParameters);

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

  Future<String?> _resolveLinuxDistribution() async {
    if (!Platform.isLinux) return null;

    try {
      final file = File('/etc/os-release');
      if (!await file.exists()) return null;
      return _linuxDistributionFromOsRelease(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  String? _linuxDistributionFromOsRelease(String contents) {
    final values = <String, String>{};
    for (final line in contents.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final separatorIndex = trimmed.indexOf('=');
      if (separatorIndex <= 0) continue;

      final key = trimmed.substring(0, separatorIndex).trim().toUpperCase();
      var value = trimmed.substring(separatorIndex + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      values[key] = value;
    }

    final candidates = <String>[
      if ((values['ID'] ?? '').trim().isNotEmpty) values['ID']!,
      ...((values['ID_LIKE'] ?? '')
          .split(RegExp(r'\s+'))
          .where((value) => value.trim().isNotEmpty)),
    ];

    for (final candidate in candidates) {
      final normalized = _normalizeLinuxDistribution(candidate);
      if (normalized != null) return normalized;
    }
    return null;
  }

  String? _normalizeLinuxDistribution(String value) {
    final key = value.trim().toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9]+'),
          '',
        );
    if (key.isEmpty) return null;
    return _linuxDistributionAliases[key];
  }

  Future<String> getCurrentVersionLabel() async {
    final currentAppVersion = await _resolveCurrentAppVersion();
    return currentAppVersion.label;
  }

  Future<bool> openUpdate(AppUpdateInfo info) async {
    if (await ServerLockdownService().isEnabled()) {
      _lastErrorMessage = ServerLockdownService().blockedMessageFor(
        'open update downloads',
      );
      return false;
    }
    final uri = Uri.tryParse(_manualDownloadPageUrl(info));
    if (uri == null) return false;

    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<bool> openManualDownloadPage([AppUpdateInfo? info]) async {
    if (await ServerLockdownService().isEnabled()) {
      _lastErrorMessage = ServerLockdownService().blockedMessageFor(
        'open manual downloads',
      );
      return false;
    }
    final uri = Uri.tryParse(_manualDownloadPageUrl(info));
    if (uri == null) return false;

    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<bool> openAndroidDownloadsFolder() async {
    if (!Platform.isAndroid) {
      return false;
    }
    if (await ServerLockdownService().isEnabled()) {
      _lastErrorMessage = ServerLockdownService().blockedMessageFor(
        'open Android downloads',
      );
      return false;
    }

    try {
      return await _storageChannel.invokeMethod<bool>('openDownloadsFolder') ??
          false;
    } catch (_) {
      _lastErrorMessage = 'Could not open the Downloads folder.';
      return false;
    }
  }

  Future<InstalledReleaseNotesResult> getInstalledReleaseNotes() async {
    final platform = currentPlatform;
    final currentAppVersion = await _resolveCurrentAppVersion();
    final version = currentAppVersion.version;
    final buildNumber = currentAppVersion.buildNumber;
    final versionLabel = currentAppVersion.label;

    if (await ServerLockdownService().isEnabled()) {
      return InstalledReleaseNotesResult(
        versionLabel: versionLabel,
        notes: ServerLockdownService().blockedMessageFor(
          'load server-hosted release notes',
        ),
      );
    }

    if (platform.isEmpty) {
      return InstalledReleaseNotesResult(
        versionLabel: versionLabel,
        notes: 'Release notes are not available for this platform.',
      );
    }

    try {
      final updateInfo = await checkForUpdate();
      final currentBuild = currentAppVersion.parsedBuildNumber;
      if (updateInfo != null &&
          updateInfo.latestVersion == version &&
          updateInfo.latestBuildNumber == currentBuild &&
          updateInfo.releaseNotes.trim().isNotEmpty) {
        return InstalledReleaseNotesResult(
          versionLabel: versionLabel,
          notes: updateInfo.releaseNotes.trim(),
        );
      }

      final appId = await _findReleaseNotesAppId(
        version: version,
        buildNumber: buildNumber,
      );
      if (appId == null) {
        return InstalledReleaseNotesResult(
          versionLabel: versionLabel,
          notes:
              'Release notes for the current installed version could not be found right now.',
        );
      }

      final response = await _dio.getUri(
        Uri.parse('${AppConfig.beatzLockAppsBaseUrl}release-notes/$appId/'),
      );
      final notes =
          response.data is Map ? response.data['notes']?.toString().trim() : '';
      return InstalledReleaseNotesResult(
        versionLabel: versionLabel,
        notes: (notes == null || notes.isEmpty)
            ? 'No release notes are available for the current installed version.'
            : notes,
      );
    } catch (_) {
      return InstalledReleaseNotesResult(
        versionLabel: versionLabel,
        notes:
            'Release notes for the current installed version could not be loaded right now.',
      );
    }
  }

  Future<AppSelfUpdateResult> installUpdate(
    AppUpdateInfo info, {
    void Function(AppDownloadProgress progress)? onReceiveProgress,
  }) async {
    if (await ServerLockdownService().isEnabled()) {
      _lastErrorMessage = ServerLockdownService().blockedMessageFor(
        'download and install updates',
      );
      return AppSelfUpdateResult(started: false, message: _lastErrorMessage!);
    }

    if (!canDownloadUpdateInApp) {
      return const AppSelfUpdateResult(
        started: false,
        message: 'In-app update download is not supported on this platform.',
      );
    }

    final downloadUri = Uri.tryParse(info.downloadUrl.trim());
    if (downloadUri == null) {
      return const AppSelfUpdateResult(
        started: false,
        message: 'The update download is not available yet.',
      );
    }

    final cancelToken = CancelToken();
    _activeDownloadCancelToken = cancelToken;
    try {
      final installerPath = await _downloadInstaller(
        info,
        downloadUri,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );
      if (Platform.isAndroid) {
        final savedPath = await _saveAndroidInstallerToDownloads(
          installerPath,
          info,
          downloadUri,
        );
        return AppSelfUpdateResult(
          started: true,
          message:
              'Update APK downloaded to $savedPath. Open Downloads to install it.',
        );
      }

      await _prepareDesktopUpdate(installerPath, info);
      return const AppSelfUpdateResult(
        started: true,
        message:
            'Update downloaded. BeatzLock will close and open the installer now.',
        requiresAppExit: true,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        return const AppSelfUpdateResult(
          started: false,
          message: 'Update download cancelled.',
          wasCancelled: true,
        );
      }
      return AppSelfUpdateResult(
        started: false,
        message: _friendlyUpdateError(e),
      );
    } catch (e) {
      return AppSelfUpdateResult(
        started: false,
        message: 'Could not start the self-updater: $e',
      );
    } finally {
      if (identical(_activeDownloadCancelToken, cancelToken)) {
        _activeDownloadCancelToken = null;
      }
    }
  }

  Future<String> _downloadInstaller(
    AppUpdateInfo info,
    Uri downloadUri, {
    required CancelToken cancelToken,
    void Function(AppDownloadProgress progress)? onReceiveProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final updateDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}beatzlock_updates',
    );
    if (!await updateDir.exists()) {
      await updateDir.create(recursive: true);
    }

    final extension = _installerExtension(downloadUri, info);
    final fileName =
        'beatzlock_${info.latestVersion}_${info.latestBuildNumber}${_downloadTargetSuffix(info)}$extension';
    final filePath = '${updateDir.path}${Platform.pathSeparator}$fileName';
    final startedAt = DateTime.now();

    try {
      await _dio.download(
        downloadUri.toString(),
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          final elapsedSeconds =
              DateTime.now().difference(startedAt).inMilliseconds / 1000;
          final averageBytesPerSecond =
              elapsedSeconds > 0 ? received / elapsedSeconds : null;
          final secondsRemaining = (averageBytesPerSecond != null &&
                  averageBytesPerSecond > 0 &&
                  total > 0 &&
                  received <= total)
              ? (total - received) / averageBytesPerSecond
              : null;

          onReceiveProgress?.call(
            AppDownloadProgress(
              receivedBytes: received,
              totalBytes: total,
              bytesPerSecond: averageBytesPerSecond,
              secondsRemaining: secondsRemaining,
            ),
          );
        },
        options: Options(
          followRedirects: true,
          responseType: ResponseType.bytes,
        ),
      );
    } on DioException {
      try {
        final partialFile = File(filePath);
        if (await partialFile.exists()) {
          await partialFile.delete();
        }
      } catch (_) {
        // Ignore cleanup failures for partially downloaded installers.
      }
      rethrow;
    }

    return filePath;
  }

  Future<void> launchPreparedUpdateAndExit() async {
    final executable = _pendingLauncherExecutable;
    final arguments = _pendingLauncherArguments;
    if (executable == null || arguments == null) {
      throw const FileSystemException('No prepared desktop update was found.');
    }

    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
    _clearPreparedUpdateState(cleanupArtifacts: false);
    if (Platform.isWindows && executable.toLowerCase().endsWith('.exe')) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    exit(0);
  }

  void _clearPreparedUpdateState({required bool cleanupArtifacts}) {
    _pendingLauncherExecutable = null;
    _pendingLauncherArguments = null;

    final cleanupPaths = List<String>.from(_pendingCleanupPaths);
    _pendingCleanupPaths.clear();
    if (cleanupArtifacts && cleanupPaths.isNotEmpty) {
      unawaited(_deletePaths(cleanupPaths));
    }
  }

  void _setPendingCleanupPaths(Iterable<String> paths) {
    final stalePaths = List<String>.from(_pendingCleanupPaths);
    _pendingCleanupPaths
      ..clear()
      ..addAll(
        paths
            .map((path) => path.trim())
            .where((path) => path.isNotEmpty)
            .toSet(),
      );

    if (stalePaths.isNotEmpty) {
      unawaited(_deletePaths(stalePaths));
    }
  }

  Future<void> _deletePaths(Iterable<String> paths) async {
    final seenPaths = <String>{};
    for (final rawPath in paths) {
      final path = rawPath.trim();
      if (path.isEmpty || !seenPaths.add(path)) {
        continue;
      }

      try {
        switch (await FileSystemEntity.type(path, followLinks: false)) {
          case FileSystemEntityType.file:
            await File(path).delete();
            break;
          case FileSystemEntityType.directory:
            await Directory(path).delete(recursive: true);
            break;
          case FileSystemEntityType.link:
            await Link(path).delete();
            break;
          case FileSystemEntityType.pipe:
          case FileSystemEntityType.unixDomainSock:
          case FileSystemEntityType.notFound:
            break;
        }
      } catch (_) {
        // Ignore best-effort update cleanup failures.
      }
    }
  }

  Future<String> _saveAndroidInstallerToDownloads(
    String installerPath,
    AppUpdateInfo info,
    Uri downloadUri,
  ) async {
    final file = File(installerPath);
    final savedPath = await _storageChannel.invokeMethod<String>(
      'saveFileToDownloads',
      {
        'fileName':
            'beatzlock_${info.latestVersion}_${info.latestBuildNumber}${_downloadTargetSuffix(info)}${_installerExtension(downloadUri, info)}',
        'mimeType': 'application/vnd.android.package-archive',
        'bytes': await file.readAsBytes(),
      },
    );
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Temporary Android update files can be safely ignored if cleanup fails.
    }

    if (savedPath == null || savedPath.isEmpty) {
      throw const FileSystemException(
        'Android Downloads save returned no path.',
      );
    }
    return savedPath;
  }

  Future<int?> _findReleaseNotesAppId({
    required String version,
    required String buildNumber,
  }) async {
    final pageUris = [
      Uri.parse('${AppConfig.beatzLockAppsBaseUrl}downloads/'),
      Uri.parse('${AppConfig.beatzLockAppsBaseUrl}downloads/archive/'),
    ];

    for (final uri in pageUris) {
      final response = await _dio.getUri(
        uri,
        options: Options(responseType: ResponseType.plain),
      );
      final html = response.data?.toString() ?? '';
      final appId = _extractReleaseNotesAppId(
        html,
        version: version,
        buildNumber: buildNumber,
      );
      if (appId != null) {
        return appId;
      }
    }

    return null;
  }

  int? _extractReleaseNotesAppId(
    String html, {
    required String version,
    required String buildNumber,
  }) {
    final pattern = RegExp(r"openNotes\('([^']*)','([^']*)',(\d+)\)");
    for (final match in pattern.allMatches(html)) {
      final entryVersion = (match.group(1) ?? '').replaceAll(r"\'", "'").trim();
      final entryBuild = (match.group(2) ?? '').replaceAll(r"\'", "'").trim();
      if (entryVersion == version && entryBuild == buildNumber) {
        return int.tryParse(match.group(3) ?? '');
      }
    }
    return null;
  }

  Future<void> _prepareDesktopUpdate(
    String installerPath,
    AppUpdateInfo info,
  ) async {
    final appPath = Platform.resolvedExecutable;
    final relaunchArgument =
        '$updateInstalledArgumentPrefix${info.latestVersion}+${info.latestBuildNumber}';
    final updateDirPath = File(installerPath).parent.path;

    if (Platform.isWindows) {
      _pendingLauncherExecutable = installerPath;
      _pendingLauncherArguments = const [];
      _setPendingCleanupPaths(<String>[updateDirPath]);
      return;
    }

    if (Platform.isLinux) {
      final scriptPath = await _writeLinuxUpdaterScript(
        installerPath,
        updateDirPath: updateDirPath,
        appPid: pid,
        appPath: appPath,
        relaunchArgument: relaunchArgument,
      );
      _pendingLauncherExecutable = scriptPath;
      _pendingLauncherArguments = const [];
      _setPendingCleanupPaths(<String>[updateDirPath, scriptPath]);
      return;
    }

    throw UnsupportedError('Desktop update is not supported on this platform.');
  }

  String _installerExtension(Uri uri, [AppUpdateInfo? info]) {
    final lastSegment =
        uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.toLowerCase();
    if (lastSegment.endsWith('.exe')) return '.exe';
    if (lastSegment.endsWith('.apk')) return '.apk';
    if (lastSegment.endsWith('.deb')) return '.deb';
    if (lastSegment.endsWith('.rpm')) return '.rpm';
    if (Platform.isWindows) return '.exe';
    if (Platform.isAndroid) return '.apk';
    if (Platform.isLinux || info?.platform == 'linux') {
      final distribution = info?.linuxDistribution.trim().toLowerCase() ?? '';
      if (distribution == 'fedora' || distribution == 'opensuse') {
        return '.rpm';
      }
      return '.deb';
    }
    return '.deb';
  }

  String _downloadTargetSuffix(AppUpdateInfo info) {
    if (info.platform != 'linux') return '';
    final distribution = info.linuxDistribution.trim().toLowerCase();
    return distribution.isEmpty ? '' : '_$distribution';
  }

  String _manualDownloadPageUrl([AppUpdateInfo? info]) {
    final pageUrl = info?.manualDownloadPageUrl ?? '';
    if (pageUrl.isNotEmpty) return pageUrl;
    return AppConfig.manualDownloadUrl;
  }

  Future<String> _writeLinuxUpdaterScript(
    String installerPath, {
    required String updateDirPath,
    required int appPid,
    required String appPath,
    required String relaunchArgument,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final script = File(
      '${tempDir.path}${Platform.pathSeparator}beatzlock_update.sh',
    );
    final escapedInstallerPath = installerPath.replaceAll("'", r"'\''");
    final escapedUpdateDirPath = updateDirPath.replaceAll("'", r"'\''");
    final escapedAppPath = appPath.replaceAll("'", r"'\''");
    final escapedRelaunchArgument = relaunchArgument.replaceAll("'", r"'\''");
    final escapedScriptPath = script.path.replaceAll("'", r"'\''");
    await script.writeAsString('''
#!/bin/sh
set -eu
PACKAGE_PATH='$escapedInstallerPath'
UPDATE_DIR='$escapedUpdateDirPath'
APP_PATH='$escapedAppPath'
APP_PID="$appPid"
APP_ARG='$escapedRelaunchArgument'
SCRIPT_PATH='$escapedScriptPath'
APP_DIR="\$(dirname "\$APP_PATH")"

show_message() {
  message="\$1"
  if command -v zenity >/dev/null 2>&1; then
    zenity --info --title="BeatzLock Update" --text="\$message" --width=380 || true
    return
  fi
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --title "BeatzLock Update" --msgbox "\$message" || true
    return
  fi
  if command -v xmessage >/dev/null 2>&1; then
    xmessage -center "\$message" || true
    return
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "BeatzLock Update" "\$message" || true
  fi
}

open_package_installer() {
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "\$PACKAGE_PATH"
    return 0
  fi
  if command -v gio >/dev/null 2>&1; then
    gio open "\$PACKAGE_PATH"
    return 0
  fi
  return 1
}

cleanup_update_artifacts() {
  if [ -f "\$PACKAGE_PATH" ]; then
    rm -f "\$PACKAGE_PATH" || true
  fi
  if [ -d "\$UPDATE_DIR" ] && [ "\$(basename "\$UPDATE_DIR")" = "beatzlock_updates" ]; then
    rm -rf "\$UPDATE_DIR" || true
  fi
}

cleanup_script() {
  if [ -f "\$SCRIPT_PATH" ]; then
    rm -f "\$SCRIPT_PATH" || true
  fi
}

reopen_app() {
  launch_arg="\$1"
  if [ ! -x "\$APP_PATH" ]; then
    return
  fi

  (
    cd "\$APP_DIR" 2>/dev/null || true
    if [ -n "\$launch_arg" ]; then
      nohup "\$APP_PATH" "\$launch_arg" >/dev/null 2>&1 &
    else
      nohup "\$APP_PATH" >/dev/null 2>&1 &
    fi
  )
}

trap cleanup_script EXIT

while kill -0 "\$APP_PID" 2>/dev/null; do
  sleep 1
done

INSTALL_STATUS=1

if [ ! -f "\$PACKAGE_PATH" ]; then
  show_message "The downloaded update package could not be found. BeatzLock will reopen so you can try again."
  cleanup_update_artifacts
  reopen_app ""
  exit 0
fi

case "\$PACKAGE_PATH" in
  *.deb)
    if command -v pkexec >/dev/null 2>&1; then
      if pkexec env DISPLAY="\${DISPLAY:-}" WAYLAND_DISPLAY="\${WAYLAND_DISPLAY:-}" XAUTHORITY="\${XAUTHORITY:-}" DEBIAN_FRONTEND=noninteractive sh -c 'dpkg -i "\$1" || apt-get install -f -y' sh "\$PACKAGE_PATH"; then
        INSTALL_STATUS=0
      fi
    fi
    if [ "\$INSTALL_STATUS" -ne 0 ] && open_package_installer; then
      show_message "The Ubuntu package installer has opened. Finish the update there, then reopen BeatzLock if it does not come back automatically."
      exit 0
    fi
    ;;
  *.rpm)
    if command -v pkexec >/dev/null 2>&1; then
      if pkexec env DISPLAY="\${DISPLAY:-}" WAYLAND_DISPLAY="\${WAYLAND_DISPLAY:-}" XAUTHORITY="\${XAUTHORITY:-}" sh -c 'if command -v dnf >/dev/null 2>&1; then dnf install -y "\$1"; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install "\$1"; else rpm -Uvh "\$1"; fi' sh "\$PACKAGE_PATH"; then
        INSTALL_STATUS=0
      fi
    fi
    if [ "\$INSTALL_STATUS" -ne 0 ] && open_package_installer; then
      show_message "The package installer has opened. Finish the update there, then reopen BeatzLock if it does not come back automatically."
      exit 0
    fi
    ;;
  *)
    if open_package_installer; then
      show_message "The installer has opened. Finish the update there, then reopen BeatzLock if it does not come back automatically."
      exit 0
    fi
    INSTALL_STATUS=1
    ;;
esac

if [ "\$INSTALL_STATUS" -eq 0 ]; then
  cleanup_update_artifacts
  show_message "The update finished installing. Click OK to reopen BeatzLock."
  reopen_app "\$APP_ARG"
else
  cleanup_update_artifacts
  show_message "The installer did not complete. BeatzLock will reopen so you can try again."
  reopen_app ""
fi
''');

    await Process.run('chmod', ['700', script.path]);
    return script.path;
  }

  String _friendlyUpdateError(DioException error) {
    final responseData = error.response?.data;
    if (responseData is Map && responseData['error'] is String) {
      final message = responseData['error'].toString().trim();
      if (message.isNotEmpty) {
        return message;
      }
    }

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

class InstalledReleaseNotesResult {
  const InstalledReleaseNotesResult({
    required this.versionLabel,
    required this.notes,
  });

  final String versionLabel;
  final String notes;
}

class _CurrentAppVersion {
  const _CurrentAppVersion({required this.version, required this.buildNumber});

  final String version;
  final String buildNumber;

  int get parsedBuildNumber => int.tryParse(buildNumber.trim()) ?? 0;

  String get label =>
      buildNumber.trim().isEmpty ? version : '$version (Build $buildNumber)';
}

class AppSelfUpdateResult {
  const AppSelfUpdateResult({
    required this.started,
    required this.message,
    this.requiresAppExit = false,
    this.wasCancelled = false,
  });

  final bool started;
  final String message;
  final bool requiresAppExit;
  final bool wasCancelled;
}

class AppDownloadProgress {
  const AppDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.secondsRemaining,
  });

  final int receivedBytes;
  final int totalBytes;
  final double? bytesPerSecond;
  final double? secondsRemaining;

  bool get hasTotal => totalBytes > 0;

  double? get ratio {
    if (!hasTotal) return null;
    return (receivedBytes / totalBytes).clamp(0, 1).toDouble();
  }

  String get percentLabel {
    final value = ratio;
    if (value == null) return 'Preparing download...';
    return '${(value * 100).toStringAsFixed(0)}%';
  }

  String get sizeLabel {
    if (!hasTotal) return 'Downloaded: ${_formatMebibytes(receivedBytes)}';
    return 'Downloaded: ${_formatMebibytes(receivedBytes)} / ${_formatMebibytes(totalBytes)}';
  }

  String get speedLabel {
    final speed = bytesPerSecond;
    if (speed == null || speed <= 0) return 'Rate: Calculating...';
    if (speed >= 1024 * 1024) return 'Rate: ${_formatMebibytes(speed)}/s avg';
    return 'Rate: ${(speed / 1024).toStringAsFixed(0)} KiB/s avg';
  }

  String get etaLabel {
    final seconds = secondsRemaining;
    if (seconds == null ||
        seconds.isNaN ||
        seconds.isInfinite ||
        seconds <= 0) {
      return 'ETA: Calculating...';
    }
    if (seconds >= 3600) {
      final hours = seconds / 3600;
      return 'ETA: ${hours.toStringAsFixed(1)} h';
    }
    if (seconds >= 60) {
      final minutes = seconds / 60;
      return 'ETA: ${minutes.toStringAsFixed(1)} min';
    }
    return 'ETA: ${seconds.toStringAsFixed(0)} s';
  }

  static String _formatMebibytes(num bytes) {
    if (bytes <= 0) return '0 MiB';
    final mebibytes = bytes / (1024 * 1024);
    if (mebibytes < 0.1) return '<0.1 MiB';
    if (mebibytes >= 100) return '${mebibytes.toStringAsFixed(0)} MiB';
    return '${mebibytes.toStringAsFixed(1)} MiB';
  }
}
