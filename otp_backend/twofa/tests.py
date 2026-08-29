from django.contrib.auth import get_user_model
from django.core import mail
from django.test import SimpleTestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient, APITestCase

from .email_templates import (
    get_2fa_email_template,
    get_delete_otp_email_template,
    get_password_changed_email_template,
    get_password_reset_email_template,
    get_recovery_codes_generated_email_template,
)

User = get_user_model()


class EmailTemplateRenderTests(SimpleTestCase):
    def test_two_factor_template_uses_beatzlock_branding(self):
        html = get_2fa_email_template('123456')

        self.assertIn('BeatzLock Authenticator', html)
        self.assertIn('Your verification code', html)
        self.assertIn('123456', html)
        self.assertNotIn('@import', html)

    def test_templates_greet_the_account_without_naming_anyone(self):
        html = get_2fa_email_template('123456')

        self.assertIn('Hello,', html)
        self.assertNotIn('Hello Felix', html)

    def test_delete_template_mentions_account_deletion(self):
        html = get_delete_otp_email_template('654321')

        self.assertIn('Confirm account deletion', html)
        self.assertIn('654321', html)

    def test_other_templates_render_without_inline_font_imports(self):
        templates = [
            get_password_changed_email_template(),
            get_password_reset_email_template('112233'),
            get_recovery_codes_generated_email_template(),
        ]

        for html in templates:
            self.assertIn('BeatzLock Authenticator', html)
            self.assertNotIn('@import', html)


@override_settings(
    EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend',
    DEFAULT_FROM_EMAIL='BeatzLock Authenticator <noreply@example.com>',
    EMAIL_HOST_USER='support@example.com',
    SUPPORT_EMAIL='info@example.com',
)
class TwoFactorEmailDeliveryTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='felix@example.com',
            password='testpass123',
        )
        self.client = APIClient()

    def test_send_2fa_returns_multipart_email(self):
        response = self.client.post(
            reverse('send_2fa'),
            {
                'username': 'felix@example.com',
                'password': 'testpass123',
            },
            format='json',
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(mail.outbox), 1)
        message = mail.outbox[0]
        self.assertEqual(message.subject, 'Your 2FA Verification Code - BeatzLock Authenticator')
        self.assertEqual(message.reply_to, ['info@example.com'])
        self.assertEqual(message.extra_headers.get('Auto-Submitted'), 'auto-generated')
        self.assertEqual(message.alternatives[0].mimetype, 'text/html')
        self.assertIn('Your verification code', message.alternatives[0].content)


@override_settings(
    EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend',
    DEFAULT_FROM_EMAIL='BeatzLock Authenticator <noreply@example.com>',
    EMAIL_HOST_USER='support@example.com',
    SUPPORT_EMAIL='info@example.com',
)
class DeleteOtpEmailDeliveryTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='adminfelix@example.com',
            password='testpass123',
        )
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def test_send_delete_otp_returns_multipart_email(self):
        response = self.client.post(reverse('send_delete_otp'), format='json')

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(mail.outbox), 1)
        message = mail.outbox[0]
        self.assertEqual(message.subject, 'BeatzLock Confirm Delete All Accounts')
        self.assertEqual(message.reply_to, ['info@example.com'])
        self.assertEqual(message.extra_headers.get('X-Auto-Response-Suppress'), 'All')
        self.assertEqual(message.alternatives[0].mimetype, 'text/html')
        self.assertIn('Confirm account deletion', message.alternatives[0].content)
