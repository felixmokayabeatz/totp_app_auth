








import 'package:flutter_test/flutter_test.dart';
import 'package:beatzlock_auth/services/sync_service.dart';

void main() {
  group('paths that must never send Authorization', () {
    const mustBeStripped = [
      'auth/login/',
      'auth/register/',
      'auth/passwordless-start/',
      'auth/passwordless-poll/',
      'send-2fa/',
      'verify-2fa/',
      'send-reset-code/',
      'reset-password/',
      'recovery-code/login/',
      'recovery-code/check-email/',
      'recovery-code/reset-password/',
    ];

    for (final path in mustBeStripped) {
      test(path, () {
        expect(SyncService.debugIsUnauthenticatedPath(path), isTrue);
      });
    }

    test('a leading slash or a full URL matches the same way', () {
      expect(SyncService.debugIsUnauthenticatedPath('/auth/login/'), isTrue);
      expect(
        SyncService.debugIsUnauthenticatedPath(
          'https://api.example.com/api/auth/login/',
        ),
        isTrue,
      );
    });
  });

  group('paths that must keep Authorization', () {


    const mustKeepAuth = [
      'sync/sync/',
      'sync/get-data/',
      'auth/unlock-sync/',
      'auth/change_password/',
      'notifications/',
      'device-sessions/heartbeat/',
      'passwordless-requests/clear-logs/',
      'backup-codes/download/',
    ];

    for (final path in mustKeepAuth) {
      test(path, () {
        expect(SyncService.debugIsUnauthenticatedPath(path), isFalse);
      });
    }

    test('a near-miss does not match by prefix', () {


      expect(
        SyncService.debugIsUnauthenticatedPath('sync/reset-password/'),
        isFalse,
      );
    });
  });
}
