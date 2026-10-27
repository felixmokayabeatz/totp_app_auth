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

    def test_model_carries_no_group_or_permission_links(self):
        field_names = {field.name for field in User._meta.get_fields()}

        self.assertNotIn('groups', field_names)
        self.assertNotIn('user_permissions', field_names)

    def test_the_join_tables_are_gone_from_the_database(self):
        from django.db import connection

        tables = set(connection.introspection.table_names())

        self.assertNotIn('auth_user_groups', tables)
        self.assertNotIn('auth_user_user_permissions', tables)
        self.assertIn('auth_user', tables)

    def test_email_is_the_login_field(self):
        self.assertEqual(User.USERNAME_FIELD, 'email')
        self.assertEqual(User.REQUIRED_FIELDS, [])
        self.assertTrue(User._meta.get_field('email').unique)

    def test_it_still_lives_in_the_auth_user_table(self):
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


class PermissionModelTests(TestCase):
    """Superuser or nothing -- there is no finer grain, and nothing to query."""

    def setUp(self):
        self.superuser = User.objects.create_superuser(
            email='admin@example.com', password='testpass123'
        )
        self.staff = User.objects.create_user(
            email='staff@example.com', password='testpass123', is_staff=True
        )
        self.ordinary = User.objects.create_user(
            email='felix@example.com', password='testpass123'
        )

    def test_a_superuser_has_everything(self):
        self.assertTrue(self.superuser.has_perm('api.change_devicesession'))
        self.assertTrue(self.superuser.has_perms(['api.add_synclog', 'users.delete_user']))
        self.assertTrue(self.superuser.has_module_perms('api'))

    def test_nobody_else_has_anything(self):
        for user in (self.staff, self.ordinary):
            with self.subTest(email=user.email):
                self.assertFalse(user.has_perm('api.change_devicesession'))
                self.assertFalse(user.has_perms(['api.add_synclog']))
                self.assertFalse(user.has_module_perms('api'))

    def test_a_deactivated_superuser_loses_everything(self):
        self.superuser.is_active = False

        self.assertFalse(self.superuser.has_perm('api.change_devicesession'))
        self.assertFalse(self.superuser.has_module_perms('api'))

    def test_checking_a_permission_costs_no_queries(self):
        with self.assertNumQueries(0):
            self.superuser.has_perm('api.change_devicesession')
            self.staff.has_perm('api.change_devicesession')


class AdminWithoutPermissionTablesTests(TestCase):
    """The admin has to keep working now that it cannot ask for permissions."""

    def setUp(self):
        self.superuser = User.objects.create_superuser(
            email='admin@example.com', password='testpass123'
        )

    def test_a_superuser_reaches_every_registered_admin_page(self):
        self.client.force_login(self.superuser)

        for url in (
            reverse('admin:index'),
            reverse('admin:users_user_changelist'),
            reverse('admin:users_user_add'),
            reverse('admin:users_user_change', args=[self.superuser.pk]),
            reverse('admin:api_devicesession_changelist'),
            reverse('admin:accounts_userprofile_changelist'),
        ):
            with self.subTest(url=url):
                self.assertEqual(self.client.get(url).status_code, 200)

    def test_staff_without_superuser_get_an_empty_admin_rather_than_an_error(self):
        staff = User.objects.create_user(
            email='staff@example.com', password='testpass123', is_staff=True
        )
        self.client.force_login(staff)

        index = self.client.get(reverse('admin:index'))
        self.assertEqual(index.status_code, 200)
        self.assertEqual(
            self.client.get(reverse('admin:users_user_changelist')).status_code,
            403,
        )

    def test_groups_are_not_in_the_admin_at_all(self):
        from django.contrib import admin
        from django.contrib.auth.models import Group

        self.assertNotIn(Group, admin.site._registry)

        self.client.force_login(self.superuser)
        html = self.client.get(reverse('admin:index')).content.decode()
        self.assertNotIn('Authentication and Authorization', html)
        self.assertNotIn('/auth/group/', html)
