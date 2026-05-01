from django.contrib.auth.models import User
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from .models import DeviceSession
from .notifications import create_notification


class DeviceSessionPrimaryChangeTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            username='felix',
            email='felix@example.com',
            password='testpass123',
        )
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

        self.primary_session = DeviceSession.objects.create(
            user=self.user,
            device_id='primary-device',
            device_label='Primary Device',
            is_primary=True,
        )
        self.current_session = DeviceSession.objects.create(
            user=self.user,
            device_id='current-device',
            device_label='Current Device',
            is_primary=False,
        )
        self.target_session = DeviceSession.objects.create(
            user=self.user,
            device_id='target-device',
            device_label='Target Device',
            is_primary=False,
        )

    def test_non_primary_current_device_cannot_change_primary_device(self):
        response = self.client.post(
            reverse('device-sessions-set-primary', args=[self.target_session.id]),
            format='json',
            HTTP_X_DEVICE_ID='current-device',
            HTTP_X_DEVICE_LABEL='Current Device',
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
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response['Content-Type'], 'application/pdf')


class AppNotificationTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            username='notify-user',
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
        notification = self.user.app_notifications.latest('created_at')
        self.assertEqual(notification.notification_type, 'app_pin_changed')
