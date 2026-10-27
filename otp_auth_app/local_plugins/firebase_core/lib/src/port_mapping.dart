



part of '../firebase_core.dart';

String getMappedHost(String originalHost) {
  String mappedHost = originalHost;

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (mappedHost == 'localhost' || mappedHost == '127.0.0.1') {

      print('Mapping Auth Emulator host "$mappedHost" to "10.0.2.2".');
      mappedHost = '10.0.2.2';
    }
  }
  return mappedHost;
}
