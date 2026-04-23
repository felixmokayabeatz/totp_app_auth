// lib/services/otp_service.dart

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'encryption_service.dart';
import 'secure_storage_service.dart';

class OTPService {
  // Singleton so all callers share the same cached userId
  static final OTPService _instance = OTPService._internal();
  factory OTPService() => _instance;
  OTPService._internal();

  String? _cachedUserId;
  final SecureStorageService _secureStorage = SecureStorageService();

  Future<String> getCurrentUserId() async {
    if (_cachedUserId != null) return _cachedUserId!;
    _cachedUserId =
        await _secureStorage.read(SecureStorageService.currentUserKey) ??
            'default_user';
    return _cachedUserId!;
  }

  void clearCachedUserId() {
    _cachedUserId = null;
  }

  /// Returns the current TOTP counter (30-second window).
  /// Using integer division means ALL calls in the same 30s window get
  /// the exact same counter → the exact same OTP for the same secret.
  int _currentCounter() {
    final epochSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return epochSeconds ~/ 30; // integer division – no floating point drift
  }

  /// Seconds remaining in the current 30-second window.
  int secondsRemaining() {
    final epochSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return 30 - (epochSeconds % 30);
  }

  Future<String> generateOTP(String encryptedSecret) async {
    if (encryptedSecret.isEmpty) return '------';

    try {
      final userId = await getCurrentUserId();
      final secret = _safeDecrypt(encryptedSecret, userId);

      final cleanSecret =
          secret.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');

      if (cleanSecret.isEmpty) {
        debugPrint('Empty secret after cleaning');
        return 'Error';
      }

      final key = _base32Decode(cleanSecret);
      if (key.isEmpty) return 'Error';

      // Use the normalised counter – same for every call in the same window
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

  String _safeDecrypt(String storedSecret, String userId) {
    final strippedSpaces = storedSecret.replaceAll(RegExp(r'\s+'), '');
    final isRawBase32 = RegExp(r'^[A-Z2-7a-z]+$').hasMatch(strippedSpaces);

    if (isRawBase32) {
      return storedSecret;
    }

    try {
      return EncryptionService.decryptSecret(storedSecret, userId);
    } catch (e) {
      debugPrint('Decryption failed: $e, using raw');
      return storedSecret;
    }
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
