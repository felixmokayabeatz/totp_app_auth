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

final sync = SyncService();

void main() {
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

  _rekeyTests();
  _localVaultIsIndependentOfSyncKey();

  test('garbage that decodes to a non-list is rejected', () {
    final key = _legacyKey('felix@gmail.com');
    final notAList = EncryptionService.simpleEncrypt('{"id":"a1"}', key);
    expect(sync.tryDecodeAccountsPayload(notAList, key), isNull);
  });
}

// The re-key repair. Negotiation above recovers a vault whose key this device
// can still construct; it cannot help an account whose old identity was never
// the email address. The key then lives only on devices already signed in --
// and when the device that lost it is the primary phone, the approval flow
// cannot rescue it either, because only the primary phone may approve and it
// cannot send itself a request. Re-keying from a device that can still read
// the vault is the way out.
void _rekeyTests() {
  final accounts = [
    {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
  ];

  test('a vault written under a legacy username re-keys to the address', () {
    // The unrecoverable class: no spelling of the address produces this key.
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

    // What repairCloudVaultKey does: read under the working key, write under
    // the one every device derives.
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
    // The old key must no longer open it -- an authenticated payload rejects a
    // wrong key outright rather than returning garbage.
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

// Why the repair reads the local vault and not the cloud one.
//
// Every device that needs repairing is a device whose sync key will not open
// the cloud blob -- that is the definition of needing it. A repair that read
// the cloud could therefore never run anywhere it was needed, which is exactly
// how the first attempt failed: every device offered "Repair" and none could
// complete it. Local secrets are encrypted under a key derived from the user id
// and its own salt, never from the password, so they stay readable no matter
// what the sync key does.
void _localVaultIsIndependentOfSyncKey() {
  const userId = 'felix@gmail.com';
  const secret = 'JBSWY3DPEHPK3PXP';

  test('local secrets do not depend on the password or the sync key', () {
    final stored = EncryptionService.encryptSecret(secret, userId);

    // Whatever the password is, and therefore whatever the sync key is, the
    // local vault opens.
    expect(EncryptionService.decryptSecret(stored, userId), secret);

    for (final password in ['old-password', 'new-password', '']) {
      final syncKey = EncryptionService.generateKey(
        userId + password,
        'beatzLockKenya2099',
      );
      expect(EncryptionService.decryptSecret(stored, userId), secret);
      expect(
          stored,
          isNot(equals(EncryptionService.simpleEncrypt(
            secret,
            syncKey,
          ))));
    }
  });

  test('a device locked out of the cloud can still republish its own vault',
      () {
    // The cloud is sealed under a key nothing can derive any more.
    final lostKey = _legacyKey('some-old-username');
    final sealed = _vaultBlob(lostKey, [
      {'id': 'a1', 'service': 'GitHub', 'secret': secret},
    ]);
    final canonical = _legacyKey(userId);
    expect(sync.tryDecodeAccountsPayload(sealed, canonical), isNull);

    // The same account, held locally, is untouched by that.
    final localAccount = EncryptionService.encryptSecret(secret, userId);
    final recovered = EncryptionService.decryptSecret(localAccount, userId);
    expect(recovered, secret);

    // So the device can rebuild the cloud vault from what it can see.
    final republished = _vaultBlob(canonical, [
      {'id': 'a1', 'service': 'GitHub', 'secret': recovered},
    ]);
    final opened = sync.tryDecodeAccountsPayload(republished, canonical);
    expect(opened, isNotNull);
    expect(opened!.single['secret'], secret);
  });
}
