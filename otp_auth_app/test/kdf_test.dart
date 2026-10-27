





import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/encryption_service.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('PBKDF2-HMAC-SHA256 published vectors', () {


    const cases = <int, String>{
      1: '120fb6cffcf8b32c43e7225256c4f837'
          'a86548c92ccc35480805987cb70be17b',
      2: 'ae4d0c95af6b46d32d0adff928f06dd0'
          '2a303f8ef3c251dfd6e2d85a95474c43',
      4096: 'c5e478d59288c841aa530db6845c4c8d'
          '962893a001ce4e11a4963873aa98134a',
    };

    cases.forEach((iterations, expected) {
      test('$iterations iterations', () {
        final actual = EncryptionService.pbkdf2(
          utf8.encode('password'),
          utf8.encode('salt'),
          iterations,
          32,
        );
        expect(_hex(actual), expected);
      });
    });

    test('a longer derived key spans multiple blocks correctly', () {


      final actual = EncryptionService.pbkdf2(
        utf8.encode('passwordPASSWORDpassword'),
        utf8.encode('saltSALTsaltSALTsaltSALTsaltSALTsalt'),
        4096,
        40,
      );
      expect(
        _hex(actual),
        '348c89dbcbd32b2f32d814b8116e84cf2b17'
        '347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9',
      );
    });
  });

  group('deriveKeyFromPassword', () {
    test('is deterministic and 32 hex characters', () {
      final a = EncryptionService.deriveKeyFromPassword('pw', 'salt',
          iterations: 1000);
      final b = EncryptionService.deriveKeyFromPassword('pw', 'salt',
          iterations: 1000);
      expect(a, b);
      expect(a.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue);
    });

    test('the salt and the iteration count both change the key', () {
      final base = EncryptionService.deriveKeyFromPassword('pw', 'salt',
          iterations: 1000);
      expect(
        EncryptionService.deriveKeyFromPassword('pw', 'pepper',
            iterations: 1000),
        isNot(base),
      );
      expect(
        EncryptionService.deriveKeyFromPassword('pw', 'salt', iterations: 1001),
        isNot(base),
      );
    });

    test('it is not the old single-SHA-256 derivation', () {


      expect(
        EncryptionService.deriveKeyFromPassword('pw', 'salt'),
        isNot(EncryptionService.generateKey('pw', 'salt')),
      );
    });

    test('the shipped iteration count is a real cost', () {
      expect(
        EncryptionService.passwordKdfIterations,
        greaterThanOrEqualTo(200000),
        reason: 'OWASP floor for PBKDF2-HMAC-SHA256',
      );
    });
  });
}
