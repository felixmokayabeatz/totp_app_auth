

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'encryption_service.dart';
import 'secure_storage_service.dart';

class OTPService {

  static final OTPService _instance = OTPService._internal();
  factory OTPService() => _instance;
  OTPService._internal();

  String? _cachedUserId;
  final SecureStorageService _secureStorage = SecureStorageService();

  Future<String> getCurrentUserId() async {
    if (_cachedUserId != null) return _cachedUserId!;
    _cachedUserId =
        await _secureStorage.read(SecureStorageService.currentUserKey) ??
            await _secureStorage.read(SecureStorageService.localVaultUserKey) ??
            'default_user';
    return _cachedUserId!;
  }

  void clearCachedUserId() {
    _cachedUserId = null;
  }




  int _currentCounter() {
    final epochSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return epochSeconds ~/ 30; 
  }


  int secondsRemaining() {
    final epochSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return 30 - (epochSeconds % 30);
  }

  Future<String> generateOTP(String encryptedSecret) async {
    if (encryptedSecret.isEmpty) return '------';

    try {
      final userId = await getCurrentUserId();
      final secret = _safeDecrypt(encryptedSecret, userId);
      if (secret == null) {

        return 'Locked';
      }

      final cleanSecret = secret.toUpperCase().replaceAll(
            RegExp(r'[^A-Z2-7]'),
            '',
          );

      if (cleanSecret.isEmpty) {
        debugPrint('Empty secret after cleaning');
        return 'Error';
      }

      final key = _base32Decode(cleanSecret);
      if (key.isEmpty) return 'Error';


      final counter = _currentCounter();

      final counterBytes = ByteData(8)..setInt64(0, counter);
      final hmac = Hmac(sha1, key);
      final hash = hmac.convert(counterBytes.buffer.asUint8List());

      final offset = hash.bytes[19] & 0xf;
      final code = ((hash.bytes[offset] & 0x7f) << 24) |
          ((hash.bytes[offset + 1] & 0xff) << 16) |
          ((hash.bytes[offset + 2] & 0xff) << 8) |
          (hash.bytes[offset + 3] & 0xff);

      return (code % 1000000).toString().padLeft(6, '0');
    } catch (e) {
      debugPrint('OTP Error: $e');
      return 'Error';
    }
  }









  String? _safeDecrypt(String storedSecret, String userId) {
    final strippedSpaces = storedSecret.replaceAll(RegExp(r'\s+'), '');
    if (_looksLikeBase32(strippedSpaces)) {

      return storedSecret;
    }

    String decrypted;
    try {
      decrypted = EncryptionService.decryptSecret(storedSecret, userId);
    } catch (e) {
      debugPrint('OTP secret could not be decrypted: $e');
      return null;
    }




    if (!_looksLikeBase32(decrypted.replaceAll(RegExp(r'\s+'), ''))) {
      debugPrint('OTP secret decrypted to something that is not base32');
      return null;
    }
    return decrypted;
  }

  static bool _looksLikeBase32(String value) {
    final cleaned = value.replaceAll('=', '');
    return cleaned.isNotEmpty && RegExp(r'^[A-Z2-7a-z]+$').hasMatch(cleaned);
  }

  Uint8List _base32Decode(String input) {
    const String alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final List<int> result = [];
    int buffer = 0;
    int bitsLeft = 0;

    for (int i = 0; i < input.length; i++) {
      final value = alphabet.indexOf(input[i]);
      if (value == -1) continue;
      buffer = (buffer << 5) | value;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        result.add((buffer >> (bitsLeft - 8)) & 0xFF);
        bitsLeft -= 8;
      }
    }

    return Uint8List.fromList(result);
  }
}
