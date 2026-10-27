




part of '../firebase_core.dart';




class FirebaseApp {





  FirebaseApp._(this._delegate) {
    FirebaseAppPlatform.verify(_delegate);
  }

  final FirebaseAppPlatform _delegate;







  Future<void> delete() async {
    final registry = _registries[name];
    if (registry != null) {
      await Future.wait(
        registry.values.map((service) {
          return service.dispose().catchError((_) {});
        }),
      );
    }

    await _delegate.delete();
    _registries.remove(name);
  }


  String get name => _delegate.name;


  FirebaseOptions get options => _delegate.options;





  bool get isAutomaticDataCollectionEnabled =>
      _delegate.isAutomaticDataCollectionEnabled;





  Future<void> setAutomaticDataCollectionEnabled(bool enabled) {
    return _delegate.setAutomaticDataCollectionEnabled(enabled);
  }



  Future<void> setAutomaticResourceManagementEnabled(bool enabled) {
    return _delegate.setAutomaticResourceManagementEnabled(enabled);
  }

  @override

  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FirebaseApp) return false;
    return other.name == name && other.options == options;
  }

  @override

  int get hashCode => Object.hash(name, options);

  @override
  String toString() => '$FirebaseApp($name)';

  static final Map<String, Map<Type, _RegisteredFirebaseService>> _registries =
      {};


  void registerService<T extends FirebaseService>(
    T service, {
    Future<void> Function(T service)? dispose,
  }) {
    final registry = _registries.putIfAbsent(name, () => {});
    registry[T] = _RegisteredFirebaseService(
      service,
      dispose == null ? null : () => dispose(service),
    );
  }


  T? getService<T extends FirebaseService>() {
    return _registries[name]?[T]?.service as T?;
  }
}


abstract class FirebaseService {}

class _RegisteredFirebaseService {
  _RegisteredFirebaseService(this.service, this._dispose);

  final FirebaseService service;
  final Future<void> Function()? _dispose;

  Future<void> dispose() async {
    await _dispose?.call();
  }
}
