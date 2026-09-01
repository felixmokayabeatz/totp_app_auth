// TOTP generation, and what it must do when it cannot read a secret.
//
// An authenticator that shows a confidently wrong code is worse than one that
// shows an error: the user has no way to tell, and blames the service they are
// trying to log into. This used to happen -- an unreadable secret had its
// non-base32 characters stripped and the ciphertext was fed to the HMAC.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beatzlock_auth/services/encryption_service.dart';
import 'package:beatzlock_auth/services/otp_service.dart';
import 'package:beatzlock_auth/services/secure_storage_service.dart';

const _seed = 'JBSWY3DPEHPK3PXP';
const _userId = 'felix@gmail.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final otp = OTPService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    EncryptionService.resetLocalVaultSecretForTest();
    SecureStorageService.resetKeychainProbeForTest();
    // The vault identity the secrets are keyed on.
    await SecureStorageService()
        .write(SecureStorageService.currentUserKey, _userId);
    otp.clearCachedUserId();
  });

  tearDown(EncryptionService.resetLocalVaultSecretForTest);

  test('a readable secret produces a six-digit code', () async {
    final code = await otp.generateOTP(_seed);
    expect(RegExp(r'^\d{6}$').hasMatch(code), isTrue, reason: 'got: $code');
  });

  test('an unreadable secret reports it instead of inventing a code', () async {
    EncryptionService.configureLocalVaultSecret('install-one');
    final stored = EncryptionService.encryptSecret(_seed, _userId);

    // Another install's secret: the wrap will not open.
    EncryptionService.configureLocalVaultSecret('install-two');
    final code = await otp.generateOTP(stored);

    expect(code, 'Locked');
    expect(
      RegExp(r'^\d{6}$').hasMatch(code),
      isFalse,
      reason: 'a wrong-but-plausible code is the failure this test exists for',
    );
  });

  test('a legacy plaintext seed is still read', () async {
    // Older builds stored some secrets unencrypted; those must keep working.
    final code = await otp.generateOTP('  jbswy3dpehpk3pxp  ');
    expect(RegExp(r'^\d{6}$').hasMatch(code), isTrue, reason: 'got: $code');
  });

  test('the same secret gives the same code inside one window', () async {
    final a = await otp.generateOTP(_seed);
    final b = await otp.generateOTP(_seed);
    expect(a, b);
  });

  test('different secrets give different codes', () async {
    final a = await otp.generateOTP(_seed);
    final b = await otp.generateOTP('KRSXG5CTMVRXEZLU');
    expect(a, isNot(b));
  });

  test('the window is 30 seconds and the countdown stays inside it', () {
    final remaining = otp.secondsRemaining();
    expect(remaining, greaterThan(0));
    expect(remaining, lessThanOrEqualTo(30));
  });
}
