class AppBuildInfo {
  const AppBuildInfo._();

  // Desktop debug/package metadata can be unavailable, so keep a fallback
  // build label in sync with pubspec.yaml for update checks and UI labels.
  static const String version = '1.7.4';
  static const String buildNumber = '41';
}
