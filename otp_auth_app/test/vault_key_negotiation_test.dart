// Regression cover for the cross-device sync break introduced when accounts
// became email-keyed.
//
// The vault key is derived from the identity the API returns as
// user["username"] plus the password, and that derivation is case-sensitive.
// The identity used to be a stored username column; it is now the email
// address, which the email-only migration lowercased in place. An account
// whose address carried a capital therefore derives one key on a device that
// signed in before the migration and a different key on one that signs in
// after -- the second device downloads the vault and cannot open it.

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

void main() {
  final sync = SyncService();
  final accounts = [
    {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
  ];

  test('lowercasing the identity changes the derived key', () {
    // The migration itself: UPDATE auth_user SET email = lower(btrim(email)).
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

    // What login() now does: the canonical identity from the API plus the
    // address the person actually typed.
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

  test('garbage that decodes to a non-list is rejected', () {
    final key = _legacyKey('felix@gmail.com');
    final notAList = EncryptionService.simpleEncrypt('{"id":"a1"}', key);
    expect(sync.tryDecodeAccountsPayload(notAList, key), isNull);
  });
}
