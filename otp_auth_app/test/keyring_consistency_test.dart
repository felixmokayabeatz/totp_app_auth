








import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/encryption_service.dart';
import 'package:beatzlock_auth/services/sync_service.dart';

const _password = 'correct horse battery staple';

String _vaultUnder(String key) => EncryptionService.encryptSensitiveSyncPayload(
      jsonEncode([
        {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
      ]),
      key,
      context: EncryptionService.otpAccountsSyncContext,
    );

void main() {
  final sync = SyncService();

  test('a key that opens the vault is recognised', () {
    final dataKey = EncryptionService.generateVaultDataKey();
    final stored = _vaultUnder(dataKey);
    expect(sync.tryDecodeAccountsPayload(stored, dataKey), isNotNull);
  });

  test('a keyring key that does not match the vault is detectable', () {


    final legacyKey = EncryptionService.generateVaultDataKey();
    final dataKey = EncryptionService.generateVaultDataKey();
    final stored = _vaultUnder(legacyKey);

    expect(
      sync.tryDecodeAccountsPayload(stored, dataKey),
      isNull,
      reason:
          'this is what the app must notice instead of trusting the keyring',
    );
    expect(
      sync.tryDecodeAccountsPayload(stored, legacyKey),
      isNotNull,
      reason: 'the vault is perfectly readable under the key it is actually in',
    );
  });

  test('the password still unwraps a keyring that names the wrong key', () {


    final wrongKey = EncryptionService.generateVaultDataKey();
    final salt = EncryptionService.generateKeyringSalt();
    final wrap = EncryptionService.wrapDataKeyWithPassword(
      wrongKey,
      _password,
      salt,
    );

    expect(
      EncryptionService.unwrapDataKeyWithPassword(wrap, _password, salt),
      wrongKey,
      reason: 'unwrapping proves the password, and nothing more',
    );
  });

  test('healing restores agreement between keyring and vault', () {


    final legacyKey = EncryptionService.generateVaultDataKey();
    final stored = _vaultUnder(legacyKey);

    final salt = EncryptionService.generateKeyringSalt();
    final healed = EncryptionService.wrapDataKeyWithPassword(
      legacyKey,
      _password,
      salt,
    );
    final recovered =
        EncryptionService.unwrapDataKeyWithPassword(healed, _password, salt);

    expect(recovered, legacyKey);
    expect(sync.tryDecodeAccountsPayload(stored, recovered!), isNotNull);
  });
}
