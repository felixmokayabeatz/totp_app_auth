from django.contrib.auth import authenticate, get_user_model
from django.core.management import call_command
from django.db import IntegrityError, transaction
from django.test import TestCase
from django.urls import reverse

User = get_user_model()


class UserModelShapeTests(TestCase):
    """The whole point of the model: an account is an address and a password."""

    def test_model_has_no_username_or_name_fields(self):
        field_names = {field.name for field in User._meta.get_fields()}

        self.assertNotIn('username', field_names)
        self.assertNotIn('first_name', field_names)
        self.assertNotIn('last_name', field_names)

    def test_email_is_the_login_field(self):
        self.assertEqual(User.USERNAME_FIELD, 'email')
        self.assertEqual(User.REQUIRED_FIELDS, [])
        self.assertTrue(User._meta.get_field('email').unique)

    def test_it_still_lives_in_the_auth_user_table(self):
        # Reusing the table is what kept every existing foreign key valid.
        self.assertEqual(User._meta.db_table, 'auth_user')


class UserManagerTests(TestCase):
    def test_create_user_lowercases_and_trims_the_address(self):
        user = User.objects.create_user(
            email='  Felix@Example.COM ', password='testpass123'
        )

        self.assertEqual(user.email, 'felix@example.com')
        self.assertEqual(str(user), 'felix@example.com')
        self.assertEqual(user.get_username(), 'felix@example.com')

    def test_create_user_requires_an_address(self):
        with self.assertRaises(ValueError):
            User.objects.create_user(email='', password='testpass123')

    def test_two_accounts_cannot_share_an_address(self):
        User.objects.create_user(email='felix@example.com', password='testpass123')

        with self.assertRaises(IntegrityError), transaction.atomic():
            User.objects.create_user(email='felix@example.com', password='otherpass456')

    def test_create_superuser_sets_both_flags(self):
        admin = User.objects.create_superuser(
            email='admin@example.com', password='testpass123'
        )

        self.assertTrue(admin.is_staff)
        self.assertTrue(admin.is_superuser)

    def test_a_profile_is_created_for_every_account(self):
        user = User.objects.create_user(email='felix@example.com', password='testpass123')

        self.assertIsNotNone(user.profile)


class EmailAuthenticationTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email='felix@example.com', password='testpass123'
        )

    def test_authenticate_accepts_any_casing(self):
        self.assertEqual(
            authenticate(username='FELIX@Example.com', password='testpass123'),
            self.user,
        )

    def test_authenticate_rejects_a_wrong_password(self):
        self.assertIsNone(authenticate(username='felix@example.com', password='nope'))


class CreateSuperuserCommandTests(TestCase):
    def test_it_takes_an_email_and_normalises_it(self):
        call_command(
            'createsuperuser',
            '--noinput',
            '--email',
            'Admin@Example.COM',
            verbosity=0,
        )

        admin = User.objects.get(email='admin@example.com')
        self.assertTrue(admin.is_superuser)

    def test_it_refuses_an_address_that_is_already_taken(self):
        User.objects.create_user(email='admin@example.com', password='testpass123')

        with self.assertRaises(Exception):
            call_command(
                'createsuperuser', '--noinput', '--email', 'ADMIN@example.com', verbosity=0
            )


class AdminSignInTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create_superuser(
            email='admin@example.com', password='testpass123'
        )

    def test_the_login_page_asks_for_an_email(self):
        html = self.client.get(reverse('admin:login')).content.decode()

        self.assertIn('Email', html)
        self.assertNotIn('Username', html)

    def test_signing_in_with_the_address_works_whatever_the_casing(self):
        response = self.client.post(
            reverse('admin:login'),
            {
                'username': 'ADMIN@example.com',
                'password': 'testpass123',
                'next': reverse('admin:index'),
            },
        )

        self.assertRedirects(response, reverse('admin:index'))

    def test_the_account_admin_pages_render(self):
        self.client.force_login(self.admin)

        for url in (
            reverse('admin:users_user_changelist'),
            reverse('admin:users_user_add'),
            reverse('admin:users_user_change', args=[self.admin.pk]),
        ):
            with self.subTest(url=url):
                self.assertEqual(self.client.get(url).status_code, 200)
