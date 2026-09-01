// Sign-in endpoints must not carry a session.
//
// DRF runs DEFAULT_AUTHENTICATION_CLASSES on any request with an Authorization
// header, before permission classes. DeviceSessionJWTAuthentication raises
// AuthenticationFailed for a revoked or expired session, so a stale token turns
// an AllowAny endpoint into a 401 -- and the app reports 401 on sign-in as
// "Invalid email or password". The credentials were never the problem, which is
// what made it so hard to read.

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
    // Stripping the header from these would break them outright: they are the
    // endpoints that require a session.
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
      // 'reset-password/' is unauthenticated; the recovery-code variant is a
      // different path and both are listed explicitly rather than by prefix.
      expect(
        SyncService.debugIsUnauthenticatedPath('sync/reset-password/'),
        isFalse,
      );
    });
  });
}
