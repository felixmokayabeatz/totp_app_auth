// Vault key escrow.
//
// The vault key is derived from the account password. A password reset happens
// precisely because the old password is gone, so before escrow existed a reset
// left the synced vault locked under a key nobody could derive again -- dead
// ciphertext, with no warning and no way back. Wrapping the key under each
// recovery code gives the PDF users are already made to save a way to open it.

import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/encryption_service.dart';

const _vaultKey = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const _code = 'K7QP2M9XZ4';

void main() {
  test('a recovery code unwraps the key it was wrapped under', () {
    final wrapped = EncryptionService.wrapVaultKey(_vaultKey, _code);
    expect(wrapped, isNot(contains(_vaultKey)));
    expect(EncryptionService.unwrapVaultKey(wrapped, _code), _vaultKey);
  });

  test('codes are matched however the user types them', () {
    final wrapped = EncryptionService.wrapVaultKey(_vaultKey, _code);
    for (final typed in ['k7qp2m9xz4', 'K7QP-2M9X-Z4', ' K7QP 2M9X Z4 ']) {
      expect(
        EncryptionService.unwrapVaultKey(wrapped, typed),
        _vaultKey,
        reason: 'should accept $typed',
      );
    }
  });

  test('a wrong code returns null rather than a plausible wrong key', () {
    // This is why the envelope is authenticated. A wrong key that silently
    // produced garbage would be handed to the vault as if it were real.
    final wrapped = EncryptionService.wrapVaultKey(_vaultKey, _code);
    for (final wrong in ['AAAAAAAAAA', 'K7QP2M9XZ5', '']) {
      expect(EncryptionService.unwrapVaultKey(wrapped, wrong), isNull);
    }
  });

  test('each code in a set independently opens the vault key', () {
    const codes = ['K7QP2M9XZ4', 'B3NR8T5WQ1', 'H9XC4V7LD2'];
    final escrow = [
      for (final code in codes) EncryptionService.wrapVaultKey(_vaultKey, code),
    ];

    for (final code in codes) {
      final opened = escrow
          .map((w) => EncryptionService.unwrapVaultKey(w, code))
          .firstWhere((key) => key != null, orElse: () => null);
      expect(opened, _vaultKey, reason: '$code should open the escrow');
    }
  });

  group('re-keys stay reachable without the codes', () {
    test('the chain leads an old escrow to the current key', () {
      // Escrow written when the vault used key one.
      const keyOne = _vaultKey;
      const keyTwo = 'ffffffff11111111222222223333333f';
      const keyThree = '99998888777766665555444433332222';

      final wrapped = EncryptionService.wrapVaultKey(keyOne, _code);

      // Two later re-keys, neither of which had the codes available.
      final chain = <String>[
        EncryptionService.chainVaultKey(keyTwo, keyOne),
        EncryptionService.chainVaultKey(keyThree, keyTwo),
      ];

      var recovered = EncryptionService.unwrapVaultKey(wrapped, _code);
      expect(recovered, keyOne);
      for (final link in chain) {
        final next = EncryptionService.unchainVaultKey(link, recovered!);
        if (next != null) recovered = next;
      }

      expect(recovered, keyThree, reason: 'chain must reach the current key');
    });

    test('a chain link does not open under the wrong previous key', () {
      final link = EncryptionService.chainVaultKey('newkey', 'oldkey');
      expect(EncryptionService.unchainVaultKey(link, 'notoldkey'), isNull);
    });
  });

  test('the wrapped blob does not leak the key or the code', () {
    final wrapped = EncryptionService.wrapVaultKey(_vaultKey, _code);
    expect(wrapped, isNot(contains(_vaultKey)));
    expect(wrapped, isNot(contains(_code)));
    expect(wrapped, startsWith('bl2:'));
  });

  test('two wraps of the same key differ, so the blob is not a fingerprint',
      () {
    // A deterministic wrap would let anyone with the stored escrow tell that
    // two accounts share a vault key, or that a key had not changed.
    final first = EncryptionService.wrapVaultKey(_vaultKey, _code);
    final second = EncryptionService.wrapVaultKey(_vaultKey, _code);
    expect(first, isNot(equals(second)));
    expect(EncryptionService.unwrapVaultKey(first, _code), _vaultKey);
    expect(EncryptionService.unwrapVaultKey(second, _code), _vaultKey);
  });
}
