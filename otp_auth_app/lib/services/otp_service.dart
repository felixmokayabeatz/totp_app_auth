import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'encryption_service.dart';

class OTPService {
  Future<String> getCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user') ?? 'default_user';
  }

  Future<String> generateOTP(String encryptedSecret) async {
    if (encryptedSecret.isEmpty) return '------';

    try {
      final userId = await getCurrentUserId();
      final secret = _safeDecrypt(encryptedSecret, userId);

      // Strip everything that is not a valid Base32 character
      final cleanSecret = secret
          .toUpperCase()
          .replaceAll(RegExp(r'[^A-Z2-7]'), '');

      if (cleanSecret.isEmpty) {
        debugPrint('Empty secret after cleaning');
        return 'Error';
      }

      debugPrint('Decoding secret: $cleanSecret');

      final key = _base32Decode(cleanSecret);
      if (key.isEmpty) return 'Error';

      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final counter = (timestamp / 30).floor();
      final counterBytes = ByteData(8)..setInt64(0, counter);
      final hmac = Hmac(sha1, key);
      final hash = hmac.convert(counterBytes.buffer.asUint8List());

      final offset = hash.bytes[19] & 0xf;
      final code = ((hash.bytes[offset] & 0x7f) << 24) |
          ((hash.bytes[offset + 1] & 0xff) << 16) |
          ((hash.bytes[offset + 2] & 0xff) << 8) |
          (hash.bytes[offset + 3] & 0xff);

      final otp = (code % 1000000).toString().padLeft(6, '0');
      debugPrint('Generated OTP: $otp');
      return otp;
    } catch (e) {
      debugPrint('OTP Error: $e');
      return 'Error';
    }
  }

  String _safeDecrypt(String storedSecret, String userId) {
    // If it looks like raw Base32 (only A-Z, 2-7, spaces) → it's unencrypted legacy
    final strippedSpaces = storedSecret.replaceAll(RegExp(r'\s+'), '');
    final isRawBase32 = RegExp(r'^[A-Z2-7a-z]+$').hasMatch(strippedSpaces);

    if (isRawBase32) {
      // Already plain Base32 — no decryption needed
      debugPrint('Secret is raw Base32, using directly');
      return storedSecret;
    }

    // Looks like base64 encrypted output — try to decrypt
    try {
      final decrypted = EncryptionService.decryptSecret(storedSecret, userId);
      debugPrint('Decrypted successfully');
      return decrypted;
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

    debugPrint('Decoded ${result.length} bytes');
    return Uint8List.fromList(result);
  }
}