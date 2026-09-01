// The vault keyring: a random data key that never changes, held wrapped under
// the password and under each recovery code.
//
// Every serious failure this app has had came out of deriving the vault key
// from the account identity and password. These tests are written as the
// failures that used to happen, so they fail loudly if the derivation ever
// creeps back in.

import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/encryption_service.dart';

const _password = 'correct horse battery staple';
const _newPassword = 'a completely different password';
const _codes = ['K7QP2M9XZ4', 'B3NR8T5WQ1', 'H9XC4V7LD2'];

void main() {
  test('a data key is random, so two accounts never share one', () {
    final keys =
        List.generate(50, (_) => EncryptionService.generateVaultDataKey());
    expect(keys.toSet().length, 50);
    expect(keys.first.length, 32);
  });

  test('the password unwraps the data key it was wrapped under', () {
    final dataKey = EncryptionService.generateVaultDataKey();
    final salt = EncryptionService.generateKeyringSalt();
    final wrap =
        EncryptionService.wrapDataKeyWithPassword(dataKey, _password, salt);

    expect(
      EncryptionService.unwrapDataKeyWithPassword(wrap, _password, salt),
      dataKey,
    );
    expect(
      EncryptionService.unwrapDataKeyWithPassword(wrap, _newPassword, salt),
      isNull,
    );
  });

  group('the failures this design removes', () {
    test('how the account identity is spelled no longer matters', () {
      // The original bug: lowercasing the stored email changed the vault key,
      // and an account whose username was never the email could not derive it
      // at all. Shown as a contrast -- the old derivation gives a different key
      // for every spelling, the new wrap has no identity in it to differ over.
      const spellings = [
        'Felix@Gmail.com',
        'felix@gmail.com',
        'felixmokayabeatz',
      ];

      final legacyKeys = {
        for (final identity in spellings)
          EncryptionService.generateKey(
              identity + _password, 'beatzLockKenya2099'),
      };
      expect(
        legacyKeys.length,
        spellings.length,
        reason: 'the old derivation produced a different key per spelling',
      );

      final dataKey = EncryptionService.generateVaultDataKey();
      final salt = EncryptionService.generateKeyringSalt();
      final wrap =
          EncryptionService.wrapDataKeyWithPassword(dataKey, _password, salt);

      // Identity is not an input, so none of those spellings can change this.
      expect(
        EncryptionService.unwrapDataKeyWithPassword(wrap, _password, salt),
        dataKey,
      );
      for (final legacyKey in legacyKeys) {
        expect(
          EncryptionService.unwrapDataKeyWithPassword(wrap, legacyKey, salt),
          isNull,
          reason: 'an identity-derived key is not the wrapping key',
        );
      }
    });

    test('a password change does not change the key the vault is under', () {
      // The vault used to be re-encrypted on every password change, which is
      // where data went missing. Now only the wrap changes.
      final dataKey = EncryptionService.generateVaultDataKey();
      final oldSalt = EncryptionService.generateKeyringSalt();
      final oldWrap = EncryptionService.wrapDataKeyWithPassword(
          dataKey, _password, oldSalt);

      final recovered = EncryptionService.unwrapDataKeyWithPassword(
        oldWrap,
        _password,
        oldSalt,
      );
      final newSalt = EncryptionService.generateKeyringSalt();
      final newWrap = EncryptionService.wrapDataKeyWithPassword(
        recovered!,
        _newPassword,
        newSalt,
      );

      expect(
        EncryptionService.unwrapDataKeyWithPassword(
          newWrap,
          _newPassword,
          newSalt,
        ),
        dataKey,
        reason: 'the data key must survive a password change untouched',
      );
      expect(
        EncryptionService.unwrapDataKeyWithPassword(
          newWrap,
          _password,
          newSalt,
        ),
        isNull,
        reason: 'the old password must stop working',
      );
    });

    test('a password reset recovers instead of orphaning the vault', () {
      // The worst one: a reset happens without the old password, so the vault
      // used to stay sealed under a key nobody could derive again. A recovery
      // code unwraps the same data key and re-wraps it under the new password.
      final dataKey = EncryptionService.generateVaultDataKey();
      final codeWraps = [
        for (final code in _codes)
          EncryptionService.wrapDataKeyWithRecoveryCode(dataKey, code),
      ];

      // The password is gone. The codes are not.
      String? recovered;
      for (final wrap in codeWraps) {
        recovered =
            EncryptionService.unwrapDataKeyWithRecoveryCode(wrap, _codes[1]);
        if (recovered != null) break;
      }
      expect(recovered, dataKey);

      final newSalt = EncryptionService.generateKeyringSalt();
      final rewrapped = EncryptionService.wrapDataKeyWithPassword(
        recovered!,
        _newPassword,
        newSalt,
      );
      expect(
        EncryptionService.unwrapDataKeyWithPassword(
          rewrapped,
          _newPassword,
          newSalt,
        ),
        dataKey,
      );
    });

    test('recovery codes keep working across a password change', () {
      // They wrap the data key, not the password, so nothing about them goes
      // stale when the password moves. This is what the escrow chain existed
      // to work around, and why the chain is no longer needed.
      final dataKey = EncryptionService.generateVaultDataKey();
      final codeWrap =
          EncryptionService.wrapDataKeyWithRecoveryCode(dataKey, _codes[0]);

      for (final password in [_password, _newPassword, 'a third one']) {
        final salt = EncryptionService.generateKeyringSalt();
        EncryptionService.wrapDataKeyWithPassword(dataKey, password, salt);
        expect(
          EncryptionService.unwrapDataKeyWithRecoveryCode(codeWrap, _codes[0]),
          dataKey,
          reason: 'codes must survive the password becoming $password',
        );
      }
    });
  });

  group('failing safely', () {
    test('a wrong code or password yields null, never a wrong key', () {
      final dataKey = EncryptionService.generateVaultDataKey();
      final salt = EncryptionService.generateKeyringSalt();
      final passwordWrap =
          EncryptionService.wrapDataKeyWithPassword(dataKey, _password, salt);
      final codeWrap =
          EncryptionService.wrapDataKeyWithRecoveryCode(dataKey, _codes[0]);

      expect(
        EncryptionService.unwrapDataKeyWithPassword(
            passwordWrap, 'wrong', salt),
        isNull,
      );
      expect(
        EncryptionService.unwrapDataKeyWithPassword(
          passwordWrap,
          _password,
          EncryptionService.generateKeyringSalt(),
        ),
        isNull,
        reason: 'the salt is part of the wrapping key',
      );
      expect(
        EncryptionService.unwrapDataKeyWithRecoveryCode(codeWrap, _codes[1]),
        isNull,
      );
    });

    test('a password wrap cannot be opened as a code wrap, or the reverse', () {
      // Separate contexts, so one kind of wrap can never be replayed as the
      // other even when the underlying secret happens to match.
      const shared = 'K7QP2M9XZ4';
      final dataKey = EncryptionService.generateVaultDataKey();
      final salt = EncryptionService.generateKeyringSalt();

      final asPassword =
          EncryptionService.wrapDataKeyWithPassword(dataKey, shared, salt);
      final asCode =
          EncryptionService.wrapDataKeyWithRecoveryCode(dataKey, shared);

      expect(
        EncryptionService.unwrapDataKeyWithRecoveryCode(asPassword, shared),
        isNull,
      );
      expect(
        EncryptionService.unwrapDataKeyWithPassword(asCode, shared, salt),
        isNull,
      );
    });

    test('the stored keyring leaks neither the key nor the password', () {
      final dataKey = EncryptionService.generateVaultDataKey();
      final salt = EncryptionService.generateKeyringSalt();
      final wrap =
          EncryptionService.wrapDataKeyWithPassword(dataKey, _password, salt);

      expect(wrap, isNot(contains(dataKey)));
      expect(wrap, isNot(contains(_password)));
      expect(wrap, startsWith('bl2:'));
    });
  });
}
