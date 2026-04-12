// auth_service.dart

import 'package:crypto/crypto.dart';

class OTPService {
  String generateOTP(String secret) {
    if (secret.isEmpty) return '------';
    
    try {
      final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
      final counter = (timestamp / 30).floor();
      
      // Simple HOTP/TOTP implementation
      final key = base32Decode(secret.toUpperCase());
      final counterBytes = _intToBytes(counter);
      
      final hmac = Hmac(sha1, key);
      final hash = hmac.convert(counterBytes);
      
      final offset = hash.bytes[19] & 0xf;
      final code = ((hash.bytes[offset] & 0x7f) << 24 |
          (hash.bytes[offset + 1] & 0xff) << 16 |
          (hash.bytes[offset + 2] & 0xff) << 8 |
          (hash.bytes[offset + 3] & 0xff)) %
          1000000;
      
      return code.toString().padLeft(6, '0');
    } catch (e) {
      return 'Error';
    }
  }
  
  List<int> _intToBytes(int value) {
    List<int> bytes = [];
    for (int i = 7; i >= 0; i--) {
      bytes.add((value >> (8 * i)) & 0xff);
    }
    return bytes;
  }
}

// Simple Base32 decoder
List<int> base32Decode(String input) {
  const String alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  List<int> result = [];
  int buffer = 0;
  int bitsLeft = 0;
  
  for (int i = 0; i < input.length; i++) {
    int value = alphabet.indexOf(input[i]);
    if (value < 0) continue;
    
    buffer = (buffer << 5) | value;
    bitsLeft += 5;
    
    if (bitsLeft >= 8) {
      result.add((buffer >> (bitsLeft - 8)) & 0xff);
      bitsLeft -= 8;
    }
  }
  
  return result;
}