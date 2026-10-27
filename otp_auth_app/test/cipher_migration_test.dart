






import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/encryption_service.dart';

const _key = 'ac35c3f79e5511125360429f0fb6e8e0';
final _vault = jsonEncode([
  {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
]);

void main() {
  group('the weakness that was replaced', () {
    test('known plaintext recovers the whole XOR key', () {

      final blob = EncryptionService.simpleEncrypt(_vault, _key);
      final cipherBytes = base64.decode(blob);
      final crib = _vault.substring(0, 32);

      final recovered = String.fromCharCodes([
        for (var i = 0; i < 32; i++) cipherBytes[i] ^ crib.codeUnitAt(i),
      ]);

      expect(recovered, _key,
          reason: 'the key falls out of a guessable prefix');
    });

    test('the authenticated format gives nothing to a known-plaintext attack',
        () {
      final blob = EncryptionService.encryptSensitiveSyncPayload(
        _vault,
        _key,
        context: EncryptionService.otpAccountsSyncContext,
      );
      final cipherBytes = base64.decode(blob.substring(4));
      final crib = _vault.substring(0, 32);


      final attempt = String.fromCharCodes([
        for (var i = 0; i < 32; i++) cipherBytes[48 + i] ^ crib.codeUnitAt(i),
      ]);
      expect(attempt, isNot(_key));
    });
  });

  group('the synced vault format', () {
    test('round-trips and rejects tampering', () {
      final blob = EncryptionService.encryptSensitiveSyncPayload(
        _vault,
        _key,
        context: EncryptionService.otpAccountsSyncContext,
      );
      expect(
        EncryptionService.decryptSensitiveSyncPayload(
          blob,
          _key,
          context: EncryptionService.otpAccountsSyncContext,
        ),
        _vault,
      );



      final raw = base64.decode(blob.substring(4));
      raw[raw.length - 1] ^= 0x01;
      expect(
        () => EncryptionService.decryptSensitiveSyncPayload(
          'bl2:${base64.encode(raw)}',
          _key,
          context: EncryptionService.otpAccountsSyncContext,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a blob written for one data type will not open as another', () {
      final blob = EncryptionService.encryptSensitiveSyncPayload(
        _vault,
        _key,
        context: EncryptionService.otpAccountsSyncContext,
      );
      expect(
        () => EncryptionService.decryptSensitiveSyncPayload(
          blob,
          _key,
          context: 'password-entries-sync',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('the downgrade path is closed', () {
    test('unauthenticated input is refused unless migration asks for it', () {
      final legacy = EncryptionService.simpleEncrypt(_vault, _key);


      expect(
        () => EncryptionService.decryptSensitiveSyncPayload(
          legacy,
          _key,
          context: EncryptionService.otpAccountsSyncContext,
        ),
        throwsA(isA<FormatException>()),
      );


      expect(
        EncryptionService.decryptSensitiveSyncPayload(
          legacy,
          _key,
          context: EncryptionService.otpAccountsSyncContext,
          allowLegacyPlaintextFallback: true,
        ),
        _vault,
      );
    });
  });

  group('local vault key', () {
    setUp(EncryptionService.resetLocalVaultSecretForTest);
    tearDown(EncryptionService.resetLocalVaultSecretForTest);

    const userId = 'felix@gmail.com';
    const secret = 'JBSWY3DPEHPK3PXP';

    test('without a per-install secret it is derivable from the email alone',
        () {

      final stored = EncryptionService.encryptSecret(secret, userId);
      final attackerKey = EncryptionService.legacyLocalKeyFor(userId);
      expect(
        EncryptionService.simpleDecrypt(stored, attackerKey),
        secret,
        reason: 'this is exactly what the per-install secret fixes',
      );
    });

    test('with one, the email is no longer enough to read it', () {
      EncryptionService.configureLocalVaultSecret('a1b2c3d4e5f6a7b8c9d0e1f2');
      final stored = EncryptionService.encryptSecret(secret, userId);

      expect(stored, startsWith('bl3:'));



      String? attackerResult;
      try {
        attackerResult = EncryptionService.simpleDecrypt(
          stored,
          EncryptionService.legacyLocalKeyFor(userId),
        );
      } catch (_) {
        attackerResult = null;
      }
      expect(attackerResult, isNot(secret));

      expect(EncryptionService.decryptSecret(stored, userId), secret);
    });

    test('data written before the secret existed still reads', () {
      final legacy = EncryptionService.encryptSecret(secret, userId);
      EncryptionService.configureLocalVaultSecret('a1b2c3d4e5f6a7b8c9d0e1f2');
      expect(EncryptionService.decryptSecret(legacy, userId), secret);
    });

    test('a different install secret cannot read another install\'s data', () {
      EncryptionService.configureLocalVaultSecret('install-one-secret-value');
      final stored = EncryptionService.encryptSecret(secret, userId);

      EncryptionService.configureLocalVaultSecret('install-two-secret-value');
      expect(
        () => EncryptionService.decryptSecret(stored, userId),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
