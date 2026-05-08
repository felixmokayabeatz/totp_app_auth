class AppUpdateInfo {
  const AppUpdateInfo({
    required this.platform,
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.latestVersion,
    required this.latestBuildNumber,
    required this.updateAvailable,
    required this.forceUpdate,
    required this.reason,
    required this.downloadUrl,
    required this.downloadsPageUrl,
    required this.releaseNotes,
  });

  final String platform;
  final String currentVersion;
  final int currentBuildNumber;
  final String latestVersion;
  final int latestBuildNumber;
  final bool updateAvailable;
  final bool forceUpdate;
  final String reason;
  final String downloadUrl;
  final String downloadsPageUrl;
  final String releaseNotes;

  bool get canDownload =>
      downloadUrl.trim().isNotEmpty || downloadsPageUrl.trim().isNotEmpty;

  String get latestLabel => '$latestVersion (Build $latestBuildNumber)';

  String get currentLabel => '$currentVersion (Build $currentBuildNumber)';

  String get preferredOpenUrl =>
      downloadUrl.trim().isNotEmpty ? downloadUrl : downloadsPageUrl;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      platform: json['platform']?.toString() ?? '',
      currentVersion: json['current_version']?.toString() ?? '',
      currentBuildNumber:
          int.tryParse(json['current_build_number']?.toString() ?? '0') ?? 0,
      latestVersion: json['latest_version']?.toString() ?? '',
      latestBuildNumber:
          int.tryParse(json['latest_build_number']?.toString() ?? '0') ?? 0,
      updateAvailable: json['update_available'] == true,
      forceUpdate: json['force_update'] == true,
      reason: json['reason']?.toString() ?? '',
      downloadUrl: json['download_url']?.toString() ?? '',
      downloadsPageUrl: json['downloads_page_url']?.toString() ?? '',
      releaseNotes: json['release_notes']?.toString() ?? '',
    );
  }
}
