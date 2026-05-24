import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServerLockdownService {
  ServerLockdownService._internal();

  static final ServerLockdownService _instance =
      ServerLockdownService._internal();
  static const String _enabledKey = 'server_lockdown_enabled_v1';
  static const String defaultFeatureSummary =
      'sign-in, sync, passwordless, updates, and all internet features';

  factory ServerLockdownService() => _instance;

  final ValueNotifier<bool> enabledListenable = ValueNotifier<bool>(false);
  bool? _cachedEnabled;

  Future<void> initialize() async {
    final enabled = await isEnabled();
    enabledListenable.value = enabled;
  }

  Future<bool> isEnabled() async {
    final cached = _cachedEnabled;
    if (cached != null) {
      return cached;
    }

    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_enabledKey) ?? false;
    _cachedEnabled = enabled;
    enabledListenable.value = enabled;
    return enabled;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    _cachedEnabled = enabled;
    enabledListenable.value = enabled;
  }

  String blockedMessageFor([String featureSummary = defaultFeatureSummary]) {
    return 'Server Lockdown is on. Turn it off in Settings to use $featureSummary.';
  }

  void attachDioInterceptor(
    Dio dio, {
    String featureSummary = defaultFeatureSummary,
  }) {
    final alreadyAttached = dio.interceptors.any(
      (interceptor) => interceptor is _ServerLockdownInterceptor,
    );
    if (alreadyAttached) {
      return;
    }

    dio.interceptors.add(
      _ServerLockdownInterceptor(service: this, featureSummary: featureSummary),
    );
  }
}

class _ServerLockdownInterceptor extends Interceptor {
  _ServerLockdownInterceptor({
    required this.service,
    required this.featureSummary,
  });

  final ServerLockdownService service;
  final String featureSummary;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!await service.isEnabled()) {
      handler.next(options);
      return;
    }

    final message = service.blockedMessageFor(featureSummary);
    handler.reject(
      DioException(
        requestOptions: options,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: 423,
          data: {'error': message, 'code': 'server_lockdown_enabled'},
        ),
        error: message,
        type: DioExceptionType.badResponse,
      ),
    );
  }
}
