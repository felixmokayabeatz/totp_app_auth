import json

from django.contrib.auth import get_user_model
from django.urls import reverse
from django.test import override_settings
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from twofa.models import EmailVerification

from .backup_codes import (
    BACKUP_CODE_COUNT,
    BACKUP_CODE_LENGTH,
    build_backup_code_entries,
    decrypt_backup_codes,
    encrypt_backup_codes,
)
from .models import (
    AccountTombstone,
    BackupCodeSet,
    DeviceSession,
    EncryptedData,
    PasswordlessLoginRequest,
)
from .notifications import (
    create_notification,
    decrypt_notification_payload,
)

User = get_user_model()


class DeviceSessionPrimaryChangeTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='felix@example.com',
            password='testpass123',
        )
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

        self.primary_session = DeviceSession.objects.create(
            user=self.user,
            device_id='primary-device',
            device_label='Primary Device',
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
            is_primary=True,
        )
        self.current_session = DeviceSession.objects.create(
            user=self.user,
            device_id='current-device',
            device_label='Current Device',
            device_kind=DeviceSession.DEVICE_KIND_DESKTOP,
            is_primary=False,
        )
        self.target_session = DeviceSession.objects.create(
            user=self.user,
            device_id='target-device',
            device_label='Target Device',
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
            is_primary=False,
        )
        self.desktop_target_session = DeviceSession.objects.create(
            user=self.user,
            device_id='desktop-target-device',
            device_label='Desktop Target Device',
            device_kind=DeviceSession.DEVICE_KIND_DESKTOP,
            is_primary=False,
        )

    def test_non_primary_current_device_cannot_change_primary_device(self):
        response = self.client.post(
            reverse('device-sessions-set-primary', args=[self.target_session.id]),
            format='json',
            HTTP_X_DEVICE_ID='current-device',
            HTTP_X_DEVICE_LABEL='Current Device',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(
            response.data['error'],
            'Only the device currently set as primary can change the primary device.',
        )

        self.primary_session.refresh_from_db()
        self.current_session.refresh_from_db()
        self.target_session.refresh_from_db()

        self.assertTrue(self.primary_session.is_primary)
        self.assertFalse(self.current_session.is_primary)
        self.assertFalse(self.target_session.is_primary)

    def test_current_primary_device_can_transfer_primary_status(self):
        response = self.client.post(
            reverse('device-sessions-set-primary', args=[self.target_session.id]),
            {'password': 'testpass123'},
            format='json',
            HTTP_X_DEVICE_ID='primary-device',
            HTTP_X_DEVICE_LABEL='Primary Device',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data, {'success': True})

        self.primary_session.refresh_from_db()
        self.target_session.refresh_from_db()

        self.assertFalse(self.primary_session.is_primary)
        self.assertTrue(self.target_session.is_primary)

    def test_current_primary_device_requires_password_to_transfer_primary_status(self):
        response = self.client.post(
            reverse('device-sessions-set-primary', args=[self.target_session.id]),
            format='json',
            HTTP_X_DEVICE_ID='primary-device',
            HTTP_X_DEVICE_LABEL='Primary Device',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            response.data['error'],
            'Enter your account password to change the primary device.',
        )

        self.primary_session.refresh_from_db()
        self.target_session.refresh_from_db()

        self.assertTrue(self.primary_session.is_primary)
        self.assertFalse(self.target_session.is_primary)

    def test_current_primary_device_rejects_wrong_password_for_primary_transfer(self):
        response = self.client.post(
            reverse('device-sessions-set-primary', args=[self.target_session.id]),
            {'password': 'wrong-password'},
            format='json',
            HTTP_X_DEVICE_ID='primary-device',
            HTTP_X_DEVICE_LABEL='Primary Device',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data['error'], 'Account password is incorrect.')

        self.primary_session.refresh_from_db()
        self.target_session.refresh_from_db()

        self.assertTrue(self.primary_session.is_primary)
        self.assertFalse(self.target_session.is_primary)

    def test_primary_device_cannot_be_revoked_remotely(self):
        response = self.client.post(
            reverse('device-sessions-revoke', args=[self.primary_session.id]),
            format='json',
            HTTP_X_DEVICE_ID='current-device',
            HTTP_X_DEVICE_LABEL='Current Device',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(
            response.data['error'],
            'The primary device cannot be signed out remotely from another device.',
        )

        self.primary_session.refresh_from_db()
        self.assertTrue(self.primary_session.is_active)
        self.assertTrue(self.primary_session.is_primary)

    def test_backup_codes_can_only_be_generated_by_primary_device(self):
        response = self.client.get(
            reverse('download_backup_codes'),
            HTTP_X_DEVICE_ID='current-device',
            HTTP_X_DEVICE_LABEL='Current Device',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(
            response.data['error'],
            'Recovery codes can only be generated from your primary device. Your primary device is Primary Device.',
        )
        self.assertEqual(response.data['primary_device_label'], 'Primary Device')
        self.assertEqual(
            response.data['primary_device']['device_label'],
            'Primary Device',
        )

    def test_primary_device_can_generate_backup_codes(self):
        response = self.client.get(
            reverse('download_backup_codes'),
            HTTP_X_DEVICE_ID='primary-device',
            HTTP_X_DEVICE_LABEL='Primary Device',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response['Content-Type'], 'application/pdf')

    def test_primary_device_cannot_move_primary_to_desktop_when_mobile_exists(self):
        response = self.client.post(
            reverse(
                'device-sessions-set-primary',
                args=[self.desktop_target_session.id],
            ),
            {'password': 'testpass123'},
            format='json',
            HTTP_X_DEVICE_ID='primary-device',
            HTTP_X_DEVICE_LABEL='Primary Device',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            response.data['error'],
            'Choose a phone as your primary device so passwordless approvals can stay on mobile.',
        )

        self.primary_session.refresh_from_db()
        self.desktop_target_session.refresh_from_db()

        self.assertTrue(self.primary_session.is_primary)
        self.assertFalse(self.desktop_target_session.is_primary)

    def test_logout_current_keeps_primary_assignment_on_logged_out_primary_device(self):
        response = self.client.post(
            reverse('device-sessions-logout-current'),
            format='json',
            HTTP_X_DEVICE_ID='primary-device',
            HTTP_X_DEVICE_LABEL='Primary Device',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data, {'success': True})

        self.primary_session.refresh_from_db()
        self.current_session.refresh_from_db()

        self.assertFalse(self.primary_session.is_active)
        self.assertTrue(self.primary_session.is_primary)
        self.assertFalse(self.current_session.is_primary)


class PasswordlessLoginFlowTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='pwless@example.com',
            password='testpass123',
        )
        self.primary_session = DeviceSession.objects.create(
            user=self.user,
            device_id='primary-phone',
            device_label='Primary Phone',
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
            is_primary=True,
        )
        self.primary_client = APIClient()
        self.primary_client.force_authenticate(user=self.user)
        self.request_client = APIClient()

    def _start_request(self):
        response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        return PasswordlessLoginRequest.objects.get(
            id=response.data['request_id'],
        )

    def _approve(self, request_obj, code):
        return self.primary_client.post(
            reverse('passwordless-requests-approve', args=[request_obj.id]),
            {'code': code},
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

    def _wrong_code_for(self, request_obj):
        correct = request_obj.get_verification_code()
        wrong = '0000' if correct != '0000' else '1111'
        self.assertNotEqual(wrong, correct)
        return wrong

    def test_approval_accepts_a_typed_code(self):
        request_obj = self._start_request()

        response = self._approve(request_obj, request_obj.get_verification_code())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        request_obj.refresh_from_db()
        self.assertEqual(
            request_obj.status,
            PasswordlessLoginRequest.STATUS_APPROVED,
        )

    def test_request_payload_never_carries_the_code_or_a_choice_list(self):
        """The approving phone must read the code off the requesting device.

        A list of candidates containing the correct code would let anyone
        holding the primary phone approve without ever seeing the other screen,
        which is what tapping one of three used to allow.
        """
        request_obj = self._start_request()

        response = self.primary_client.get(
            reverse('passwordless-requests-list'),
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        payload = response.data[0]
        self.assertNotIn('verification_choices', payload)
        code = request_obj.get_verification_code()
        self.assertNotIn(code, json.dumps(response.data, default=str))

    def test_wrong_code_spends_one_attempt_and_reports_the_remainder(self):
        request_obj = self._start_request()

        response = self._approve(request_obj, self._wrong_code_for(request_obj))

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data['attempts_remaining'], 4)
        request_obj.refresh_from_db()
        self.assertEqual(request_obj.attempts, 1)
        self.assertEqual(
            request_obj.status,
            PasswordlessLoginRequest.STATUS_PENDING,
        )

    def test_guessing_is_capped_and_retires_the_request(self):
        request_obj = self._start_request()
        wrong = self._wrong_code_for(request_obj)

        for _ in range(PasswordlessLoginRequest.MAX_ATTEMPTS):
            self._approve(request_obj, wrong)

        request_obj.refresh_from_db()
        self.assertEqual(
            request_obj.status,
            PasswordlessLoginRequest.STATUS_EXPIRED,
        )

        # Even the correct code cannot revive a request whose budget is spent.
        response = self._approve(request_obj, request_obj.get_verification_code())
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        request_obj.refresh_from_db()
        self.assertNotEqual(
            request_obj.status,
            PasswordlessLoginRequest.STATUS_APPROVED,
        )

    def test_a_correct_code_still_works_after_a_wrong_one(self):
        request_obj = self._start_request()

        self._approve(request_obj, self._wrong_code_for(request_obj))
        response = self._approve(request_obj, request_obj.get_verification_code())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        request_obj.refresh_from_db()
        self.assertEqual(
            request_obj.status,
            PasswordlessLoginRequest.STATUS_APPROVED,
        )

    def test_passwordless_request_can_be_started_approved_and_completed(self):
        start_response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(start_response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(start_response.data['success'])
        self.assertEqual(len(start_response.data['verification_code']), 4)
        self.assertTrue(start_response.data['unlock_transfer_key'])
        self.assertEqual(start_response.data['primary_device_label'], 'Primary Phone')

        request_id = start_response.data['request_id']
        request_obj = PasswordlessLoginRequest.objects.get(id=request_id)
        self.assertEqual(
            request_obj.status,
            PasswordlessLoginRequest.STATUS_PENDING,
        )
        self.assertEqual(request_obj.requester_device_kind, DeviceSession.DEVICE_KIND_DESKTOP)
        self.assertNotEqual(
            request_obj.verification_code,
            start_response.data['verification_code'],
        )
        self.assertEqual(
            request_obj.get_verification_code(),
            start_response.data['verification_code'],
        )
        self.assertEqual(
            request_obj.get_unlock_transfer_key(),
            start_response.data['unlock_transfer_key'],
        )
        self.assertNotEqual(
            request_obj.unlock_transfer_key,
            start_response.data['unlock_transfer_key'],
        )
        self.assertTrue(
            self.user.app_notifications.filter(
                notification_type='passwordless_request',
            ).exists()
        )

        approve_response = self.primary_client.post(
            reverse('passwordless-requests-approve', args=[request_id]),
            {'code': request_obj.get_verification_code()},
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(approve_response.status_code, status.HTTP_200_OK)
        self.assertEqual(approve_response.data, {'success': True})

        poll_response = self.request_client.post(
            reverse('auth-passwordless-poll'),
            {'request_id': request_id},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(poll_response.status_code, status.HTTP_200_OK)
        self.assertTrue(poll_response.data['success'])
        self.assertEqual(poll_response.data['status'], 'approved')
        self.assertEqual(poll_response.data['requires_password_for_sync'], True)
        self.assertEqual(
            poll_response.data['unlock_transfer_key'],
            start_response.data['unlock_transfer_key'],
        )
        self.assertIn('access', poll_response.data)
        self.assertIn('refresh', poll_response.data)

        request_obj.refresh_from_db()
        self.assertEqual(
            request_obj.status,
            PasswordlessLoginRequest.STATUS_COMPLETED,
        )
        self.assertEqual(request_obj.reviewed_by_session_id, self.primary_session.id)
        self.assertIsNotNone(request_obj.completed_at)
        self.assertEqual(request_obj.unlock_transfer_key, '')
        self.assertTrue(
            self.user.app_notifications.filter(
                notification_type='sign_in',
            ).exists()
        )

    def test_passwordless_approval_can_transfer_sync_unlock_payload(self):
        start_response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(start_response.status_code, status.HTTP_201_CREATED)
        request_id = start_response.data['request_id']
        request_obj = PasswordlessLoginRequest.objects.get(id=request_id)
        sync_unlock_payload = 'bl2:temporary-sync-key-transfer'

        approve_response = self.primary_client.post(
            reverse('passwordless-requests-approve', args=[request_id]),
            {
                'code': request_obj.get_verification_code(),
                'sync_unlock_payload': sync_unlock_payload,
            },
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(approve_response.status_code, status.HTTP_200_OK)

        poll_response = self.request_client.post(
            reverse('auth-passwordless-poll'),
            {'request_id': request_id},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(poll_response.status_code, status.HTTP_200_OK)
        self.assertTrue(poll_response.data['success'])
        self.assertFalse(poll_response.data['requires_password_for_sync'])
        self.assertEqual(
            poll_response.data['sync_unlock_payload'],
            sync_unlock_payload,
        )
        self.assertEqual(
            poll_response.data['unlock_transfer_key'],
            start_response.data['unlock_transfer_key'],
        )

        request_obj.refresh_from_db()
        self.assertEqual(request_obj.sync_unlock_payload, '')
        self.assertEqual(request_obj.unlock_transfer_key, '')
        self.assertIsNotNone(request_obj.sync_unlock_transferred_at)

    def test_passwordless_start_rejects_wrong_password_when_password_is_provided(self):
        response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {
                'username': self.user.email,
                'password': 'wrong-password',
            },
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data['fallback_to_password'], True)
        self.assertEqual(response.data['error'], 'Invalid email or password.')
        self.assertFalse(
            PasswordlessLoginRequest.objects.filter(user=self.user).exists()
        )

    def test_passwordless_start_returns_account_not_available_for_unknown_email(self):
        response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': 'missing-user@example.com'},
            format='json',
            HTTP_X_DEVICE_ID='ghost-device',
            HTTP_X_DEVICE_LABEL='Ghost Device',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(response.data['error'], 'Account not available.')

    def test_passwordless_start_signs_in_immediately_on_current_primary_device(self):
        response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data['success'])
        self.assertEqual(response.data['status'], 'authenticated')
        self.assertTrue(response.data['requires_password_for_sync'])
        self.assertIn('access', response.data)
        self.assertIn('refresh', response.data)
        self.assertFalse(
            PasswordlessLoginRequest.objects.filter(user=self.user).exists()
        )

    def test_passwordless_start_on_current_primary_device_with_password_unlocks_sync(self):
        response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {
                'username': self.user.email,
                'password': 'testpass123',
            },
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data['success'])
        self.assertEqual(response.data['status'], 'authenticated')
        self.assertFalse(response.data['requires_password_for_sync'])
        self.assertIn('access', response.data)
        self.assertIn('refresh', response.data)
        self.assertFalse(
            PasswordlessLoginRequest.objects.filter(user=self.user).exists()
        )

    def test_logged_out_primary_device_can_still_sign_in_passwordlessly_on_same_device(self):
        self.primary_session.is_active = False
        self.primary_session.save(update_fields=['is_active', 'updated_at'])

        response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data['success'])
        self.assertEqual(response.data['status'], 'authenticated')
        self.assertFalse(
            PasswordlessLoginRequest.objects.filter(user=self.user).exists()
        )

    def test_other_device_falls_back_when_primary_device_is_logged_out(self):
        self.primary_session.is_active = False
        self.primary_session.save(update_fields=['is_active', 'updated_at'])

        response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(response.data['fallback_to_password'], True)
        self.assertEqual(response.data['primary_device_label'], 'Primary Phone')
        self.assertIn('signed out', response.data['error'].lower())
        self.assertIn('recovery', response.data['error'].lower())
        self.assertFalse(
            PasswordlessLoginRequest.objects.filter(user=self.user).exists()
        )

    def test_passwordless_start_falls_back_when_primary_is_not_mobile(self):
        self.primary_session.device_kind = DeviceSession.DEVICE_KIND_DESKTOP
        self.primary_session.save(update_fields=['device_kind', 'updated_at'])

        response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(response.data['fallback_to_password'], True)
        self.assertIn('phone', response.data['error'].lower())

    def test_only_primary_phone_can_approve_passwordless_request(self):
        start_response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )
        request_id = start_response.data['request_id']

        other_client = APIClient()
        other_client.force_authenticate(user=self.user)
        DeviceSession.objects.create(
            user=self.user,
            device_id='desktop-reviewer',
            device_label='Desktop Reviewer',
            device_kind=DeviceSession.DEVICE_KIND_DESKTOP,
            is_primary=False,
        )

        response = other_client.post(
            reverse('passwordless-requests-approve', args=[request_id]),
            format='json',
            HTTP_X_DEVICE_ID='desktop-reviewer',
            HTTP_X_DEVICE_LABEL='Desktop Reviewer',
            HTTP_X_DEVICE_KIND='desktop',
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(
            response.data['error'],
            'Only your current primary device can approve passwordless sign-ins.',
        )

    def test_passwordless_request_list_keeps_completed_logs_without_code(self):
        start_response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )
        request_id = start_response.data['request_id']
        request_obj = PasswordlessLoginRequest.objects.get(id=request_id)

        self.primary_client.post(
            reverse('passwordless-requests-approve', args=[request_id]),
            {'code': request_obj.get_verification_code()},
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )
        self.request_client.post(
            reverse('auth-passwordless-poll'),
            {'request_id': request_id},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        response = self.primary_client.get(
            reverse('passwordless-requests-list'),
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]['status'], 'completed')
        self.assertNotIn('verification_code', response.data[0])
        self.assertIn('created_at', response.data[0])
        self.assertIn('updated_at', response.data[0])
        self.assertIn('completed_at', response.data[0])

    def test_passwordless_request_notification_hides_verification_code(self):
        start_response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )
        self.assertEqual(start_response.status_code, status.HTTP_201_CREATED)

        notification = self.user.app_notifications.get(
            notification_type='passwordless_request',
        )
        payload = decrypt_notification_payload(notification.encrypted_payload)

        self.assertNotIn(start_response.data['verification_code'], payload['details'])
        self.assertNotIn('verification_code', payload.get('metadata', {}))

    def test_only_primary_phone_can_delete_or_clear_passwordless_logs(self):
        start_response = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )
        request_id = start_response.data['request_id']
        request_obj = PasswordlessLoginRequest.objects.get(id=request_id)

        self.primary_client.post(
            reverse('passwordless-requests-approve', args=[request_id]),
            {'code': request_obj.get_verification_code()},
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )
        self.request_client.post(
            reverse('auth-passwordless-poll'),
            {'request_id': request_id},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        other_client = APIClient()
        other_client.force_authenticate(user=self.user)
        DeviceSession.objects.create(
            user=self.user,
            device_id='desktop-reviewer',
            device_label='Desktop Reviewer',
            device_kind=DeviceSession.DEVICE_KIND_DESKTOP,
            is_primary=False,
        )

        delete_response = other_client.post(
            reverse('passwordless-requests-delete-log', args=[request_id]),
            format='json',
            HTTP_X_DEVICE_ID='desktop-reviewer',
            HTTP_X_DEVICE_LABEL='Desktop Reviewer',
            HTTP_X_DEVICE_KIND='desktop',
        )
        self.assertEqual(delete_response.status_code, status.HTTP_403_FORBIDDEN)

        clear_response = other_client.post(
            reverse('passwordless-requests-clear-logs'),
            format='json',
            HTTP_X_DEVICE_ID='desktop-reviewer',
            HTTP_X_DEVICE_LABEL='Desktop Reviewer',
            HTTP_X_DEVICE_KIND='desktop',
        )
        self.assertEqual(clear_response.status_code, status.HTTP_403_FORBIDDEN)

    def test_clear_logs_preserves_pending_requests(self):
        completed_start = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )
        completed_id = completed_start.data['request_id']
        completed_request = PasswordlessLoginRequest.objects.get(id=completed_id)

        self.primary_client.post(
            reverse('passwordless-requests-approve', args=[completed_id]),
            {'code': completed_request.get_verification_code()},
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )
        self.request_client.post(
            reverse('auth-passwordless-poll'),
            {'request_id': completed_id},
            format='json',
            HTTP_X_DEVICE_ID='laptop-01',
            HTTP_X_DEVICE_LABEL='Studio Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )

        pending_start = self.request_client.post(
            reverse('auth-passwordless-start'),
            {'username': self.user.email},
            format='json',
            HTTP_X_DEVICE_ID='laptop-02',
            HTTP_X_DEVICE_LABEL='Travel Laptop',
            HTTP_X_DEVICE_KIND='desktop',
        )
        pending_id = pending_start.data['request_id']

        clear_response = self.primary_client.post(
            reverse('passwordless-requests-clear-logs'),
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(clear_response.status_code, status.HTTP_200_OK)
        self.assertEqual(clear_response.data['cleared_count'], 1)
        self.assertFalse(
            PasswordlessLoginRequest.objects.filter(id=completed_id).exists()
        )
        self.assertTrue(
            PasswordlessLoginRequest.objects.filter(
                id=pending_id,
                status=PasswordlessLoginRequest.STATUS_PENDING,
            ).exists()
        )


class PrimarySingleDeleteAccountTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='delete@example.com',
            password='testpass123',
        )
        self.primary_client = APIClient()
        self.primary_client.force_authenticate(user=self.user)
        self.secondary_client = APIClient()
        self.secondary_client.force_authenticate(user=self.user)

        self.primary_session = DeviceSession.objects.create(
            user=self.user,
            device_id='primary-phone',
            device_label='Primary Phone',
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
            is_primary=True,
        )
        self.secondary_session = DeviceSession.objects.create(
            user=self.user,
            device_id='tablet-01',
            device_label='Tablet',
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
            is_primary=False,
        )

    def test_primary_single_delete_requires_exact_phrase(self):
        response = self.primary_client.post(
            reverse('sync-delete-account-everywhere'),
            {
                'account_id': 'otp-123',
                'confirmation_phrase': 'DELETE',
            },
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            response.data['error'],
            'Type Delete Account Everywhere to confirm this permanent cloud deletion.',
        )
        self.assertFalse(
            AccountTombstone.objects.filter(
                user=self.user,
                account_id='otp-123',
            ).exists()
        )

    def test_primary_single_delete_is_blocked_on_non_primary_device(self):
        response = self.secondary_client.post(
            reverse('sync-delete-account-everywhere'),
            {
                'account_id': 'otp-456',
                'confirmation_phrase': 'Delete Account Everywhere',
            },
            format='json',
            HTTP_X_DEVICE_ID='tablet-01',
            HTTP_X_DEVICE_LABEL='Tablet',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(
            response.data['error'],
            'Only your primary device can delete synced OTP accounts everywhere.',
        )
        self.assertFalse(
            AccountTombstone.objects.filter(
                user=self.user,
                account_id='otp-456',
            ).exists()
        )

    def test_primary_single_delete_succeeds_with_exact_phrase(self):
        response = self.primary_client.post(
            reverse('sync-delete-account-everywhere'),
            {
                'account_id': 'otp-789',
                'confirmation_phrase': 'Delete Account Everywhere',
            },
            format='json',
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['success'], True)
        self.assertTrue(
            AccountTombstone.objects.filter(
                user=self.user,
                account_id='otp-789',
            ).exists()
        )


class PrimaryDeviceRecoveryTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='recover@example.com',
            password='testpass123',
        )
        self.old_primary_session = DeviceSession.objects.create(
            user=self.user,
            device_id='old-primary-phone',
            device_label='Old Primary Phone',
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
            is_primary=True,
        )
        self.recovery_code = 'ABCD1234EF'
        BackupCodeSet.objects.create(
            user=self.user,
            encrypted_codes=encrypt_backup_codes(
                build_backup_code_entries([self.recovery_code])
            ),
        )
        EmailVerification.objects.create(
            user=self.user,
            code='123456',
            is_used=False,
        )
        self.client = APIClient()

    def test_recover_primary_device_requires_phone_and_rotates_primary(self):
        response = self.client.post(
            reverse('auth-recover-primary-device'),
            {
                'username': self.user.email,
                'password': 'testpass123',
                'email_code': '123456',
                'recovery_code': self.recovery_code,
                'device_id': 'new-primary-phone',
                'device_label': 'New Primary Phone',
                'device_kind': 'mobile',
            },
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data['success'])
        self.assertEqual(response.data['remaining_codes'], 0)
        self.assertIn('access', response.data)
        self.assertIn('refresh', response.data)

        self.old_primary_session.refresh_from_db()
        new_primary = DeviceSession.objects.get(
            user=self.user,
            device_id='new-primary-phone',
        )
        verification = EmailVerification.objects.get(user=self.user, code='123456')

        self.assertFalse(self.old_primary_session.is_primary)
        self.assertTrue(new_primary.is_primary)
        self.assertEqual(new_primary.device_kind, DeviceSession.DEVICE_KIND_MOBILE)
        self.assertTrue(verification.is_used)
        self.assertTrue(
            self.user.app_notifications.filter(
                notification_type='recovery_code_used',
            ).exists()
        )

    def test_recover_primary_device_rejects_desktop_target(self):
        response = self.client.post(
            reverse('auth-recover-primary-device'),
            {
                'username': self.user.email,
                'password': 'testpass123',
                'email_code': '123456',
                'recovery_code': self.recovery_code,
                'device_id': 'desktop-target',
                'device_label': 'Desktop Target',
                'device_kind': 'desktop',
            },
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            response.data['error'],
            'Primary-device recovery must finish on a phone so your primary device stays mobile.',
        )


class AppNotificationTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='notify@example.com',
            password='testpass123',
        )
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

        create_notification(
            self.user,
            'sign_in',
            title='Signed in on a device',
            message='Unread notification 1',
        )
        create_notification(
            self.user,
            'account_added',
            title='Account added',
            message='Unread notification 2',
        )
        self.already_read = create_notification(
            self.user,
            'password_changed',
            title='Password changed',
            message='Already read notification',
        )
        self.already_read.is_read = True
        self.already_read.read_at = self.already_read.created_at
        self.already_read.save(update_fields=['is_read', 'read_at', 'updated_at'])

    def test_mark_all_notifications_read_marks_only_unread_items(self):
        response = self.client.post(
            reverse('notifications-mark-all-read'),
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['success'], True)
        self.assertEqual(response.data['marked_count'], 2)

        unread_count = self.user.app_notifications.filter(is_read=False).count()
        self.assertEqual(unread_count, 0)
        self.assertEqual(self.user.app_notifications.filter(read_at__isnull=True).count(), 0)

    def test_clear_notifications_filters_by_type_and_keeps_unread(self):
        response = self.client.post(
            reverse('notifications-clear'),
            {
                'notification_type': 'password_changed',
                'keep_unread': True,
            },
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['success'], True)
        self.assertEqual(response.data['deleted_count'], 1)
        self.assertFalse(
            self.user.app_notifications.filter(notification_type='password_changed').exists()
        )
        self.assertEqual(self.user.app_notifications.count(), 2)

    def test_clear_notifications_rejects_invalid_age_filter(self):
        response = self.client.post(
            reverse('notifications-clear'),
            {'older_than_days': 'old-ish'},
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_log_app_pin_changed_notification_records_device(self):
        response = self.client.post(
            reverse('notifications-log-event'),
            {
                'event_type': 'app_pin_changed',
                'device_label': 'Windows - Studio PC',
            },
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(
            self.user.app_notifications.filter(
                notification_type='app_pin_changed'
            ).exists()
        )

    def test_log_accounts_imported_notification_creates_summary(self):
        response = self.client.post(
            reverse('notifications-log-event'),
            {
                'event_type': 'accounts_imported',
                'imported_count': 71,
                'skipped_count': 4,
                'source_label': 'totp-export.csv',
            },
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(
            self.user.app_notifications.filter(
                notification_type='accounts_imported'
            ).exists()
        )

    def test_log_passwords_imported_notification_creates_summary(self):
        response = self.client.post(
            reverse('notifications-log-event'),
            {
                'event_type': 'passwords_imported',
                'imported_count': 12,
                'source_label': 'passwords.json',
            },
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(
            self.user.app_notifications.filter(
                notification_type='passwords_imported'
            ).exists()
        )
@override_settings(BEATZLOCK_INTERNAL_SERVICE_SECRET='shared-review-secret')
class ExternalReviewReplyNotificationTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='review@example.com',
            password='testpass123',
        )
        self.client = APIClient()

    def test_external_reply_creates_in_app_notification(self):
        response = self.client.post(
            reverse('receive_external_review_reply'),
            {
                'user_id': str(self.user.id),
                'email': self.user.email,
                'platform_label': 'Android (APK)',
                'stars': 5,
                'display_name': 'Felix',
                'admin_reply': 'Thanks for the review and support.',
            },
            format='json',
            HTTP_X_BEATZLOCK_SERVICE_SECRET='shared-review-secret',
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        notification = self.user.app_notifications.latest('created_at')
        self.assertEqual(notification.notification_type, 'app_review_reply')

    def test_external_reply_rejects_wrong_secret(self):
        response = self.client.post(
            reverse('receive_external_review_reply'),
            {
                'user_id': str(self.user.id),
                'platform_label': 'Windows (EXE)',
                'stars': 4,
                'admin_reply': 'Reply text.',
            },
            format='json',
            HTTP_X_BEATZLOCK_SERVICE_SECRET='wrong-secret',
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class BackupCodeEscrowHeaderTests(APITestCase):
    """The PDF download hands the codes back so the app can escrow its key.

    The vault key is derived from the password and never leaves the device, so
    the escrow can only be built where both the key and the plaintext codes are
    in hand -- which is the app, at the moment it downloads a freshly generated
    PDF. The codes are the same ones already inside that PDF, going to the same
    authenticated user.
    """

    def setUp(self):
        self.user = User.objects.create_user(
            email='escrow@example.com',
            password='testpass123',
        )
        self.session = DeviceSession.objects.create(
            user=self.user,
            device_id='primary-phone',
            device_label='Primary Phone',
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
            is_primary=True,
        )
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def _download(self):
        return self.client.get(
            reverse('download_backup_codes'),
            HTTP_X_DEVICE_ID='primary-phone',
            HTTP_X_DEVICE_LABEL='Primary Phone',
            HTTP_X_DEVICE_KIND='mobile',
        )

    def test_download_returns_the_generated_codes_in_a_header(self):
        response = self._download()

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response['Content-Type'], 'application/pdf')
        codes = [c for c in response['X-Backup-Codes'].split(',') if c]
        self.assertEqual(len(codes), BACKUP_CODE_COUNT)
        for code in codes:
            self.assertEqual(len(code), BACKUP_CODE_LENGTH)
            self.assertTrue(code.isalnum())
            self.assertEqual(code, code.upper())

    def test_header_codes_are_the_ones_stored_for_the_account(self):
        response = self._download()
        codes = response['X-Backup-Codes'].split(',')

        code_set = BackupCodeSet.objects.get(user=self.user)
        stored = {
            entry['code']
            for entry in decrypt_backup_codes(code_set.encrypted_codes)
        }
        self.assertEqual(set(codes), stored)

    def test_each_download_rotates_the_codes(self):
        first = self._download()['X-Backup-Codes']
        second = self._download()['X-Backup-Codes']
        self.assertNotEqual(first, second)

    def test_codes_are_not_exposed_to_an_unauthenticated_caller(self):
        anonymous = APIClient()
        response = anonymous.get(reverse('download_backup_codes'))
        self.assertIn(
            response.status_code,
            (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN),
        )
        self.assertNotIn('X-Backup-Codes', response)


class SyncVersionGuardTests(APITestCase):
    """The server refuses an upload built on a copy that is no longer current.

    This used to be a bare update_or_create that took the client's version
    number without comparing it and kept no previous copy, so any client could
    overwrite a vault outright -- including one that had just failed to decrypt
    what was there. The client refuses to do that now, but the rule only means
    something if it is enforced where the data lives.
    """

    def setUp(self):
        self.user = User.objects.create_user(
            email='sync@example.com',
            password='testpass123',
        )
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def _upload(self, content, version):
        return self.client.post(
            reverse('sync-sync'),
            {
                'data_type': 'otp_accounts',
                'encrypted_content': content,
                'version': version,
                'device_id': 'device-a',
            },
            format='json',
        )

    def _stored(self):
        return EncryptedData.objects.get(
            user=self.user, data_type='otp_accounts'
        )

    def test_a_first_upload_is_stored(self):
        response = self._upload('bl2:first', 1)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(self._stored().encrypted_content, 'bl2:first')

    def test_a_newer_version_replaces_the_stored_copy(self):
        self._upload('bl2:first', 1)
        response = self._upload('bl2:second', 2)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(self._stored().encrypted_content, 'bl2:second')

    def test_a_stale_version_is_rejected_and_changes_nothing(self):
        self._upload('bl2:current', 5)

        response = self._upload('bl2:stale', 3)

        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertTrue(response.data['conflict'])
        self.assertEqual(response.data['current_version'], 5)
        self.assertEqual(self._stored().encrypted_content, 'bl2:current')

    def test_the_same_version_is_rejected_too(self):
        # Two devices that both read version 5 and both send 6: the second one
        # built its upload without seeing the first, so it cannot be trusted to
        # replace it.
        self._upload('bl2:current', 5)

        response = self._upload('bl2:concurrent', 5)

        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(self._stored().encrypted_content, 'bl2:current')

    def test_a_non_numeric_version_is_refused(self):
        response = self.client.post(
            reverse('sync-sync'),
            {
                'data_type': 'otp_accounts',
                'encrypted_content': 'bl2:whatever',
                'version': 'not-a-number',
                'device_id': 'device-a',
            },
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_each_data_type_versions_independently(self):
        self._upload('bl2:accounts', 9)
        response = self.client.post(
            reverse('sync-sync'),
            {
                'data_type': 'password_entries',
                'encrypted_content': 'bl2:passwords',
                'version': 1,
                'device_id': 'device-a',
            },
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
