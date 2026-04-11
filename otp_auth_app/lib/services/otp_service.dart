import 'package:crypto/crypto.dart';

class OTPService {
  String generateOTP(String secret) {
    if (secret.isEmpty) return '------';
    
    try {
      // Get current time counter (30-second intervals)
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final counter = (timestamp / 30).floor();
      
      // Convert counter to bytes
      final counterBytes = _intToBytes(counter);
      
      // Decode base32 secret
      final key = _base32Decode(secret.toUpperCase().replaceAll(' ', ''));
      
      // Generate HMAC-SHA1
      final hmac = Hmac(sha1, key);
      final hash = hmac.convert(counterBytes);
      
      // Dynamic truncation
      final offset = hash.bytes[19] & 0xf;
      final code = ((hash.bytes[offset] & 0x7f) << 24 |
          (hash.bytes[offset + 1] & 0xff) << 16 |
          (hash.bytes[offset + 2] & 0xff) << 8 |
          (hash.bytes[offset + 3] & 0xff)) % 1000000;
      
      // Return 6-digit code with leading zeros
      return code.toString().padLeft(6, '0');
    } catch (e) {
      print('OTP Error: $e');
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
  
  List<int> _base32Decode(String input) {
    const String alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    List<int> result = [];
    int buffer = 0;
    int bitsLeft = 0;
    
    for (int i = 0; i < input.length; i++) {
      final char = input[i];
      final value = alphabet.indexOf(char);
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
}