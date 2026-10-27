




part of '../firebase_core.dart';


class Firebase {

  Firebase._();






  @visibleForTesting

  static FirebasePlatform? delegatePackingProperty;

  static FirebasePlatform get _delegate {
    return delegatePackingProperty ??= FirebasePlatform.instance;
  }


  static List<FirebaseApp> get apps {
    return _delegate.apps.map(FirebaseApp._).toList(growable: false);
  }
















  static Future<FirebaseApp> initializeApp({
    String? name,
    FirebaseOptions? options,
    String? demoProjectId,
  }) async {
    FirebaseOptions? resolvedOptions = options;
    if (demoProjectId != null) {
      late final String platformString;
      if (defaultTargetPlatform == TargetPlatform.android) {
        platformString = 'android';
      } else if (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS) {
        platformString = 'ios';
      } else {

        platformString = 'web';
      }



      name ??= demoProjectId;




      resolvedOptions = FirebaseOptions(
        apiKey: '12345',
        appId: '1:1:$platformString:1',
        messagingSenderId: '',
        projectId: demoProjectId,
      );

    }
    FirebaseAppPlatform app = await _delegate.initializeApp(
      name: name,
      options: resolvedOptions,
    );

    return FirebaseApp._(app);
  }





  static FirebaseApp app([String name = defaultFirebaseAppName]) {
    FirebaseAppPlatform app = _delegate.app(name);

    return FirebaseApp._(app);
  }


  @override

  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Firebase) return false;
    return other.hashCode == hashCode;
  }

  @override

  int get hashCode => toString().hashCode;

  @override
  String toString() => '$Firebase';
}
