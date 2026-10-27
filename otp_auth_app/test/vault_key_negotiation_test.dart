










import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/encryption_service.dart';
import 'package:beatzlock_auth/services/sync_service.dart';

const _salt = 'beatzLockKenya2099';
const _password = 'correct horse battery staple';

String _legacyKey(String identity) =>
    EncryptionService.generateKey(identity + _password, _salt);

String _vaultBlob(String key, List<Map<String, String>> accounts) =>
    EncryptionService.simpleEncrypt(jsonEncode(accounts), key);

final sync = SyncService();

void main() {
  final accounts = [
    {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
  ];

  test('lowercasing the identity changes the derived key', () {

    expect(
      _legacyKey('Felix@Gmail.com'),
      isNot(equals(_legacyKey('felix@gmail.com'))),
    );
  });

  test('a vault written under the old spelling does not open under the new',
      () {
    final blob = _vaultBlob(_legacyKey('Felix@Gmail.com'), accounts);
    expect(
      sync.tryDecodeAccountsPayload(blob, _legacyKey('felix@gmail.com')),
      isNull,
    );
  });

  test('candidate keys cover both spellings, canonical first', () {
    final keys = sync.candidateVaultKeys(
      ['felix@gmail.com', 'Felix@Gmail.com'],
      _password,
    );
    expect(keys.first, _legacyKey('felix@gmail.com'));
    expect(keys, contains(_legacyKey('Felix@Gmail.com')));
  });

  test('candidate keys are deduplicated for an already-lowercase identity', () {
    final keys = sync.candidateVaultKeys(['felix@gmail.com'], _password);
    expect(keys, hasLength(1));
  });

  test('probing the candidates recovers a vault written pre-migration', () {
    final blob = _vaultBlob(_legacyKey('Felix@Gmail.com'), accounts);



    final keys = sync.candidateVaultKeys(
      ['felix@gmail.com', 'Felix@Gmail.com'],
      _password,
    );
    final opened = keys
        .map((key) => sync.tryDecodeAccountsPayload(blob, key))
        .firstWhere((decoded) => decoded != null, orElse: () => null);

    expect(opened, isNotNull);
    expect(opened!.single['service'], 'GitHub');
  });

  test('a wrong password opens nothing, so no candidate is accepted', () {
    final blob = _vaultBlob(_legacyKey('Felix@Gmail.com'), accounts);
    final keys = sync.candidateVaultKeys(
      ['felix@gmail.com', 'Felix@Gmail.com'],
      'not the password',
    );
    for (final key in keys) {
      expect(sync.tryDecodeAccountsPayload(blob, key), isNull);
    }
  });

  _rekeyTests();
  _repairIsNonDestructive();

  test('garbage that decodes to a non-list is rejected', () {
    final key = _legacyKey('felix@gmail.com');
    final notAList = EncryptionService.simpleEncrypt('{"id":"a1"}', key);
    expect(sync.tryDecodeAccountsPayload(notAList, key), isNull);
  });
}








void _rekeyTests() {
  final accounts = [
    {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
  ];

  test('a vault written under a legacy username re-keys to the address', () {

    final legacy = _legacyKey('felix');
    final canonical = _legacyKey('felix@gmail.com');
    final blob = _vaultBlob(legacy, accounts);

    expect(sync.tryDecodeAccountsPayload(blob, canonical), isNull);
    for (final key in sync.candidateVaultKeys(
      ['felix@gmail.com', 'Felix@Gmail.com'],
      _password,
    )) {
      expect(sync.tryDecodeAccountsPayload(blob, key), isNull);
    }



    final plain = EncryptionService.simpleDecrypt(blob, legacy);
    final rewritten = EncryptionService.simpleEncrypt(plain, canonical);

    final opened = sync.tryDecodeAccountsPayload(rewritten, canonical);
    expect(opened, isNotNull);
    expect(opened!.single['secret'], 'JBSWY3DPEHPK3PXP');
  });

  test('re-keying preserves the authenticated formats byte for byte', () {
    const context = 'password-entries-sync';
    final oldKey = _legacyKey('felix');
    final newKey = _legacyKey('felix@gmail.com');
    final entries = jsonEncode([
      {'id': 'p1', 'title': 'Router', 'password': 'hunter2'},
    ]);

    final stored = EncryptionService.encryptSensitiveSyncPayload(
      entries,
      oldKey,
      context: context,
    );
    final plain = EncryptionService.decryptSensitiveSyncPayload(
      stored,
      oldKey,
      context: context,
    );
    final rewritten = EncryptionService.encryptSensitiveSyncPayload(
      plain,
      newKey,
      context: context,
    );

    expect(
      EncryptionService.decryptSensitiveSyncPayload(
        rewritten,
        newKey,
        context: context,
      ),
      entries,
    );


    expect(
      () => EncryptionService.decryptSensitiveSyncPayload(
        rewritten,
        oldKey,
        context: context,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}








void _repairIsNonDestructive() {
  const password = _password;

  test('a key that opens the cloud is found before anything is written', () {


    final workingKey = _legacyKey('Felix@Gmail.com');
    final canonical = _legacyKey('felix@gmail.com');
    final stored = _vaultBlob(workingKey, [
      {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
    ]);

    final rescueKeys = <String>[
      workingKey,
      ...sync.candidateVaultKeys(
        ['felix@gmail.com', 'Felix@Gmail.com'],
        password,
      ),
    ];
    final opened = rescueKeys
        .map((key) => sync.tryDecodeAccountsPayload(stored, key))
        .firstWhere((decoded) => decoded != null, orElse: () => null);

    expect(opened, isNotNull, reason: 'repair must read before it writes');


    final rewritten = _vaultBlob(canonical, [
      for (final account in opened!) Map<String, String>.from(account as Map),
    ]);
    final reread = sync.tryDecodeAccountsPayload(rewritten, canonical);
    expect(reread, isNotNull);
    expect(reread!.single['secret'], 'JBSWY3DPEHPK3PXP');
  });

  test('no derivable key opens a vault sealed under a lost identity', () {


    final sealed = _vaultBlob(_legacyKey('some-old-username'), [
      {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
    ]);

    final rescueKeys = sync.candidateVaultKeys(
      ['felix@gmail.com', 'Felix@Gmail.com'],
      password,
    );
    for (final key in rescueKeys) {
      expect(sync.tryDecodeAccountsPayload(sealed, key), isNull);
    }


    expect(
      sync.tryDecodeAccountsPayload(sealed, _legacyKey('some-old-username')),
      isNotNull,
      reason: 'the sealed vault is still intact for whoever holds its key',
    );
  });

  test('local storage is unaffected by any of this', () {


    const userId = 'felix@gmail.com';
    const secret = 'JBSWY3DPEHPK3PXP';
    final stored = EncryptionService.encryptSecret(secret, userId);

    for (final candidate in ['old-password', 'new-password', '']) {
      expect(
        EncryptionService.decryptSecret(stored, userId),
        secret,
        reason: 'password $candidate must not affect local storage',
      );
    }
  });
}
