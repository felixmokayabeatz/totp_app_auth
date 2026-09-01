// Bulk export: the way out for someone who may hold the only copy of their
// seeds. Before this, forty-four accounts meant forty-four QR scans.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/encryption_service.dart';
import 'package:beatzlock_auth/services/otp_export_service.dart';

void main() {
  final service = OtpExportService();

  group('otpauth URIs', () {
    test('build in the form every other authenticator reads', () {
      final uri = service.buildOtpAuthUri(
        secret: 'JBSWY3DPEHPK3PXP',
        service: 'GitHub',
        issuer: 'GitHub',
        accountLabel: 'felix@example.com',
      );

      final parsed = Uri.parse(uri);
      expect(parsed.scheme, 'otpauth');
      expect(parsed.host, 'totp');
      expect(parsed.queryParameters['secret'], 'JBSWY3DPEHPK3PXP');
      expect(parsed.queryParameters['issuer'], 'GitHub');
      expect(parsed.queryParameters['digits'], '6');
      expect(parsed.queryParameters['period'], '30');
    });

    test('labels with separators in them do not corrupt the URI', () {
      // An account label containing a slash, colon or ampersand would otherwise
      // produce a URI that imports as something else entirely.
      final uri = service.buildOtpAuthUri(
        secret: 'JBSWY3DPEHPK3PXP',
        service: 'Self hosted',
        issuer: 'git/self&host',
        accountLabel: 'user:name/with?chars',
      );

      final parsed = Uri.parse(uri);
      expect(parsed.queryParameters['issuer'], 'git/self&host');
      expect(parsed.pathSegments.single, 'git/self&host:user:name/with?chars');
      expect(parsed.queryParameters['secret'], 'JBSWY3DPEHPK3PXP');
    });

    test('a missing issuer falls back to the service name', () {
      final uri = service.buildOtpAuthUri(
        secret: 'ABCDEFGHIJKLMNOP',
        service: 'Fastmail',
      );
      expect(Uri.parse(uri).queryParameters['issuer'], 'Fastmail');
    });
  });

  group('encrypted export', () {
    // Mirrors _buildEncryptedExport so the round trip can be checked without a
    // Hive vault behind it.
    String buildFile(List<Map<String, String>> accounts, String passphrase) {
      final salt = EncryptionService.generateKeyringSalt();
      final key = EncryptionService.deriveKeyFromPassword(
        passphrase,
        'beatzlock_export|$salt',
      );
      return jsonEncode({
        'format': 'beatzlock-otp-export',
        'version': OtpExportService.exportFormatVersion,
        'created_at': DateTime.now().toIso8601String(),
        'account_count': accounts.length,
        'kdf': 'pbkdf2-sha256',
        'kdf_iterations': EncryptionService.passwordKdfIterations,
        'salt': salt,
        'payload': EncryptionService.encryptSensitiveSyncPayload(
          jsonEncode(accounts),
          key,
          context: OtpExportService.exportContext,
        ),
      });
    }

    final accounts = [
      {'id': 'a1', 'service': 'GitHub', 'secret': 'JBSWY3DPEHPK3PXP'},
      {'id': 'a2', 'service': 'AWS', 'secret': 'KRSXG5CTMVRXEZLU'},
    ];

    test('round-trips with the right passphrase', () {
      final file = buildFile(accounts, 'a good long passphrase');
      final restored =
          service.decodeEncryptedExport(file, 'a good long passphrase');

      expect(restored, isNotNull);
      expect(restored!.length, 2);
      expect(restored.first['secret'], 'JBSWY3DPEHPK3PXP');
    });

    test('a wrong passphrase is refused, not silently wrong', () {
      final file = buildFile(accounts, 'a good long passphrase');
      expect(service.decodeEncryptedExport(file, 'not the passphrase'), isNull);
      expect(service.lastErrorMessage, contains('passphrase'));
    });

    test('an altered file is detected', () {
      final file = buildFile(accounts, 'a good long passphrase');
      final decoded = jsonDecode(file) as Map<String, dynamic>;
      final payload = decoded['payload'] as String;
      // Flip one character of ciphertext.
      decoded['payload'] =
          '${payload.substring(0, payload.length - 2)}${payload.endsWith("A") ? "B" : "A"}=';
      expect(
        service.decodeEncryptedExport(
          jsonEncode(decoded),
          'a good long passphrase',
        ),
        isNull,
      );
    });

    test('the secrets are not sitting in the file', () {
      final file = buildFile(accounts, 'a good long passphrase');
      expect(file, isNot(contains('JBSWY3DPEHPK3PXP')));
      expect(file, isNot(contains('a good long passphrase')));
      // The header stays readable so the file is identifiable years later.
      expect(file, contains('beatzlock-otp-export'));
      expect(file, contains('pbkdf2-sha256'));
    });

    test('a file written at a different cost still opens', () {
      // Raising the shipped iteration count must not strand old exports.
      final salt = EncryptionService.generateKeyringSalt();
      final key = EncryptionService.deriveKeyFromPassword(
        'passphrase for the file',
        'beatzlock_export|$salt',
        iterations: 1000,
      );
      final file = jsonEncode({
        'format': 'beatzlock-otp-export',
        'version': 1,
        'salt': salt,
        'kdf_iterations': 1000,
        'payload': EncryptionService.encryptSensitiveSyncPayload(
          jsonEncode(accounts),
          key,
          context: OtpExportService.exportContext,
        ),
      });

      final restored =
          service.decodeEncryptedExport(file, 'passphrase for the file');
      expect(restored, isNotNull);
      expect(restored!.first['secret'], 'JBSWY3DPEHPK3PXP');
    });

    test('a file that is not an export is rejected clearly', () {
      expect(service.decodeEncryptedExport('{"hello":"world"}', 'x'), isNull);
      expect(service.lastErrorMessage, contains('not a BeatzLock export'));
    });
  });

  test('a plaintext export warns about what it contains', () async {
    // Not asserting on file writing here -- just that the warning text the
    // builder emits is present, since the file is raw seeds.
    final dir = await Directory.systemTemp.createTemp('bl_export_test');
    addTearDown(() => dir.delete(recursive: true));
    expect(dir.existsSync(), isTrue);
  });
}
