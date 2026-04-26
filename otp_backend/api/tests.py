from django.contrib.auth.models import User
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from .models import DeviceSession


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
