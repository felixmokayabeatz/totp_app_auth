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


@override_settings(EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend')
class VerificationCodeBruteForceTests(APITestCase):
    """A six-digit code is only safe while the number of guesses is bounded."""

    def setUp(self):
        self.user = User.objects.create_user(
            email='felix@example.com', password='testpass123'
        )
        self.client = APIClient()

    def _issue_code(self):
        from .models import EmailVerification

        return EmailVerification.objects.create(user=self.user)

    def _guess(self, code):
        return self.client.post(
            reverse('verify_2fa'),
            {'email': self.user.email, 'code': code},
            format='json',
        )

    def _wrong_code_for(self, verification):
        return '000000' if verification.code != '000000' else '111111'

    def test_a_code_is_retired_after_five_wrong_guesses(self):
        from .models import EmailVerification

        verification = self._issue_code()
        wrong = self._wrong_code_for(verification)

        for _ in range(EmailVerification.MAX_ATTEMPTS):
            self.assertEqual(self._guess(wrong).status_code, 400)

        verification.refresh_from_db()
        self.assertTrue(verification.is_used)
        self.assertFalse(verification.is_valid())

        # Even the right code no longer works once the budget is spent.
        self.assertEqual(self._guess(verification.code).status_code, 400)

    def test_the_response_says_how_many_guesses_are_left(self):
        verification = self._issue_code()

        response = self._guess(self._wrong_code_for(verification))

        self.assertEqual(response.data['attempts_remaining'], 4)

    def test_a_correct_code_still_verifies_and_is_consumed(self):
        verification = self._issue_code()

        response = self._guess(verification.code)

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['success'])
        verification.refresh_from_db()
        self.assertTrue(verification.is_used)

    def test_password_reset_stops_accepting_guesses_too(self):
        from .models import EmailVerification

        verification = self._issue_code()
        wrong = self._wrong_code_for(verification)

        for _ in range(EmailVerification.MAX_ATTEMPTS):
            response = self.client.post(
                reverse('reset_password'),
                {
                    'email': self.user.email,
                    'code': wrong,
                    'new_password': 'brand-new-password',
                },
                format='json',
            )
            self.assertEqual(response.status_code, 400)

        # The real code is now worthless, so the password cannot be changed
        # by anyone who guessed their way here.
        response = self.client.post(
            reverse('reset_password'),
            {
                'email': self.user.email,
                'code': verification.code,
                'new_password': 'brand-new-password',
            },
            format='json',
        )
        self.assertEqual(response.status_code, 400)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password('testpass123'))

    def test_codes_come_from_a_cryptographic_source(self):
        from .models import EmailVerification

        codes = {EmailVerification.objects.create(user=self.user).code for _ in range(50)}

        self.assertGreater(len(codes), 40)
        for code in codes:
            self.assertEqual(len(code), 6)
            self.assertTrue(code.isdigit())

    def test_an_expired_code_is_rejected_before_it_is_compared(self):
        from datetime import timedelta

        from django.utils import timezone

        from .models import EmailVerification

        verification = self._issue_code()
        EmailVerification.objects.filter(pk=verification.pk).update(
            created_at=timezone.now() - timedelta(minutes=11)
        )
        verification.refresh_from_db()

        response = self._guess(verification.code)

        self.assertEqual(response.status_code, 400)
        verification.refresh_from_db()
        self.assertEqual(verification.attempts, 0)
