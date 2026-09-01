// AES-256-GCM, and the two older formats it has to keep reading.
//
// The previous construction was a hand-rolled SHA-256 keystream with an HMAC
// over it -- encrypt-then-MAC, random nonce, constant-time compare, so not
// broken as far as anyone could tell. "As far as anyone could tell" is not the
// bar for a 2FA vault. This is a reviewed implementation of a reviewed
// primitive; these tests pin its behaviour and the migration path.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/encryption_service.dart';

const _key = 'ac35c3f79e5511125360429f0fb6e8e0';
const _context = 'otp-accounts-sync';
const _plain = '[{"id":"a1","secret":"JBSWY3DPEHPK3PXP"}]';

void main() {
  group('AES-256-GCM', () {
    test('round-trips and writes the bl3 format', () {
      final sealed = EncryptionService.authenticatedEncrypt(
        _plain,
        _key,
        context: _context,
      );
      expect(sealed, startsWith('bl3:'));
      expect(
        EncryptionService.authenticatedDecrypt(sealed, _key, context: _context),
        _plain,
      );
    });

    test('the ciphertext carries neither key nor plaintext', () {
      final sealed = EncryptionService.authenticatedEncrypt(
        _plain,
        _key,
        context: _context,
      );
      expect(sealed, isNot(contains(_key)));
      expect(sealed, isNot(contains('JBSWY3DPEHPK3PXP')));
    });

    test('the nonce is fresh every time', () {
      final a = EncryptionService.authenticatedEncrypt(_plain, _key,
          context: _context);
      final b = EncryptionService.authenticatedEncrypt(_plain, _key,
          context: _context);
      expect(a, isNot(b), reason: 'a repeated GCM nonce is catastrophic');
    });

    test('a wrong key fails the tag rather than returning something', () {
      final sealed = EncryptionService.authenticatedEncrypt(
        _plain,
        _key,
        context: _context,
      );
      expect(
        () => EncryptionService.authenticatedDecrypt(
          sealed,
          'ffffffffffffffffffffffffffffffff',
          context: _context,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('any altered byte is rejected', () {
      final sealed = EncryptionService.authenticatedEncrypt(
        _plain,
        _key,
        context: _context,
      );
      final raw = base64.decode(sealed.substring(4));

      for (final index in [0, 6, raw.length ~/ 2, raw.length - 1]) {
        final tampered = List<int>.from(raw);
        tampered[index] ^= 0x01;
        expect(
          () => EncryptionService.authenticatedDecrypt(
            'bl3:${base64.encode(tampered)}',
            _key,
            context: _context,
          ),
          throwsA(isA<FormatException>()),
          reason: 'byte $index must be covered by the tag',
        );
      }
    });

    test('a payload cannot be replayed into another context', () {
      final sealed = EncryptionService.authenticatedEncrypt(
        _plain,
        _key,
        context: _context,
      );
      expect(
        () => EncryptionService.authenticatedDecrypt(
          sealed,
          _key,
          context: 'password-entries-sync',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('it handles payloads spanning many blocks', () {
      final long = List.generate(5000, (i) => 'account-$i').join(',');
      final sealed = EncryptionService.authenticatedEncrypt(
        long,
        _key,
        context: _context,
      );
      expect(
        EncryptionService.authenticatedDecrypt(sealed, _key, context: _context),
        long,
      );
    });

    test('unicode survives the round trip', () {
      const text = 'Ünïcødé — 日本語 — emoji 🔐';
      final sealed = EncryptionService.authenticatedEncrypt(
        text,
        _key,
        context: _context,
      );
      expect(
        EncryptionService.authenticatedDecrypt(sealed, _key, context: _context),
        text,
      );
    });
  });

  group('reading what is already stored', () {
    test('bl2 payloads still open, so existing data is not stranded', () {
      // Written the way the previous version wrote it.
      final legacy = _legacyBl2(_plain, _key, _context);
      expect(legacy, startsWith('bl2:'));
      expect(
        EncryptionService.authenticatedDecrypt(legacy, _key, context: _context),
        _plain,
        reason: 'a stored vault must survive the format change',
      );
    });

    test('a bl2 payload re-encrypts to bl3 with the same contents', () {
      final legacy = _legacyBl2(_plain, _key, _context);
      final plain = EncryptionService.authenticatedDecrypt(
        legacy,
        _key,
        context: _context,
      );
      final upgraded = EncryptionService.authenticatedEncrypt(
        plain,
        _key,
        context: _context,
      );

      expect(upgraded, startsWith('bl3:'));
      expect(
        EncryptionService.authenticatedDecrypt(upgraded, _key,
            context: _context),
        _plain,
      );
    });

    test('the unauthenticated original is still gated', () {
      final ancient = EncryptionService.simpleEncrypt(_plain, _key);
      expect(
        () => EncryptionService.authenticatedDecrypt(ancient, _key,
            context: _context),
        throwsA(isA<FormatException>()),
      );
      expect(
        EncryptionService.authenticatedDecrypt(
          ancient,
          _key,
          context: _context,
          allowLegacyPlaintextFallback: true,
        ),
        _plain,
      );
    });
  });
}

/// Reproduces the pre-AES bl2 format, so the migration path is tested against
/// something actually shaped like what is stored rather than a stub.
String _legacyBl2(String plainText, String key, String context) {
  final nonce = List<int>.generate(16, (i) => (i * 7 + 3) & 0xff);
  final input = utf8.encode(plainText);
  final encKey = sha256.convert(utf8.encode('$key|enc|$context')).bytes;
  final authKey = sha256.convert(utf8.encode('$key|auth|$context')).bytes;

  final encrypted = <int>[];
  var block = 0;
  while (encrypted.length < input.length) {
    final keystream = sha256.convert([
      ...encKey,
      ...nonce,
      ...utf8.encode(':$block'),
    ]).bytes;
    for (final byte in keystream) {
      if (encrypted.length >= input.length) break;
      encrypted.add(input[encrypted.length] ^ byte);
    }
    block++;
  }

  final mac = Hmac(sha256, authKey)
      .convert([...utf8.encode(context), ...nonce, ...encrypted]).bytes;
  return 'bl2:${base64Encode([...nonce, ...mac, ...encrypted])}';
}
