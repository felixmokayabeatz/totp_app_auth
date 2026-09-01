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
            await _secureStorage.read(SecureStorageService.localVaultUserKey) ??
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
      if (secret == null) {
        // Say so, rather than generate a confident wrong answer.
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

  /// The account's base32 seed, or null if this device cannot read it.
  ///
  /// Null matters. This used to fall back to returning the stored ciphertext,
  /// which then had its non-base32 characters stripped and was fed to the HMAC
  /// -- producing a stable, plausible, completely wrong six-digit code with no
  /// indication anything was amiss. For an authenticator that is the worst
  /// available behaviour: a visible error costs the user a support question,
  /// silently wrong codes cost them access and they cannot tell why.
  String? _safeDecrypt(String storedSecret, String userId) {
    final strippedSpaces = storedSecret.replaceAll(RegExp(r'\s+'), '');
    if (_looksLikeBase32(strippedSpaces)) {
      // Stored unencrypted by an older build. Genuinely the seed.
      return storedSecret;
    }

    String decrypted;
    try {
      decrypted = EncryptionService.decryptSecret(storedSecret, userId);
    } catch (e) {
      debugPrint('OTP secret could not be decrypted: $e');
      return null;
    }

    // The unauthenticated legacy format cannot report a wrong key, so a bad
    // key yields plausible-looking bytes rather than an error. Anything that is
    // not a base32 seed is treated as a failure to read it.
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
