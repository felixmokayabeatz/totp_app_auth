import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beatzlock_auth/services/secure_storage_service.dart';

/// The storage key is derived from the machine, and the keystream from that
/// key. Both were rebuilt on every read and write and are now computed once,
/// so what matters is that the values already on disk still come back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = SecureStorageService();
  });

  test('a written value reads back exactly', () async {
    await storage.write(SecureStorageService.userEmailKey, 'felix@example.com');

    expect(
      await storage.read(SecureStorageService.userEmailKey),
      'felix@example.com',
    );
  });

  test('long values survive the multi-block keystream', () async {
    // A JWT is the longest thing this store holds, and it spans many more
    // blocks than the 32 bytes one SHA-256 round covers.
    final token = 'eyJhbGciOiJIUzI1NiJ9.${'A' * 700}.signature';

    await storage.write(SecureStorageService.accessTokenKey, token);

    expect(await storage.read(SecureStorageService.accessTokenKey), token);
  });

  test('values on a block boundary are not truncated', () async {
    for (final length in [31, 32, 33, 64, 65]) {
      final value = 'x' * length;
      await storage.write(SecureStorageService.currentUserKey, value);

      expect(
        await storage.read(SecureStorageService.currentUserKey),
        value,
        reason: 'a $length-byte value came back wrong',
      );
    }
  });

  test('non-ascii text round-trips', () async {
    const value = 'héllo wörld 你好 🎧';

    await storage.write(SecureStorageService.currentUserKey, value);

    expect(await storage.read(SecureStorageService.currentUserKey), value);
  });

  test('repeated writes stay readable, so the key is stable across calls',
      () async {
    // If the derived key were recomputed differently on a later call, the
    // first value would stop decrypting.
    await storage.write(SecureStorageService.userIdKey, 'first');
    await storage.write(SecureStorageService.userEmailKey, 'second@example.com');

    expect(await storage.read(SecureStorageService.userIdKey), 'first');
    expect(
      await storage.read(SecureStorageService.userEmailKey),
      'second@example.com',
    );
  });

  test('the stored form is not the plain text', () async {
    await storage.write(SecureStorageService.currentUserKey, 'felix@example.com');

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(SecureStorageService.currentUserKey);

    expect(stored, isNotNull);
    expect(stored, startsWith('bls1:'));
    expect(stored, isNot(contains('felix@example.com')));
  });

  test('a value written before encryption existed is migrated on read',
      () async {
    SharedPreferences.setMockInitialValues({
      SecureStorageService.currentUserKey: 'legacy-plaintext@example.com',
    });

    expect(
      await storage.read(SecureStorageService.currentUserKey),
      'legacy-plaintext@example.com',
    );

    // ...and is rewritten in the encrypted form rather than left in the clear.
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(SecureStorageService.currentUserKey),
      startsWith('bls1:'),
    );
  });

  test('an unreadable value is dropped rather than thrown', () async {
    SharedPreferences.setMockInitialValues({
      SecureStorageService.currentUserKey: 'bls1:not-valid-base64!!',
    });

    expect(await storage.read(SecureStorageService.currentUserKey), isNull);
  });

  test('a missing key reads as null', () async {
    expect(await storage.read(SecureStorageService.appPinHashKey), isNull);
  });
}
