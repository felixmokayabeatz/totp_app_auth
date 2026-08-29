"""The account model for this API: an email address and a password, nothing else.

Nobody has ever signed in here with a username. Every login path -- the app, the
2FA codes, the password reset, the admin -- resolves an account by email, and
``RegisterSerializer`` only ever copied the address into ``auth_user.username``
to satisfy a column Django required. ``first_name`` and ``last_name`` were never
collected at all. This model drops all three.

``Meta.db_table`` deliberately stays ``auth_user``. Reusing the table the stock
model already owned turns the switch into three ``DROP COLUMN``s instead of a
table rebuild, and leaves the fifteen foreign keys that point at ``auth_user``
-- device sessions, encrypted vault rows, admin log entries -- attached to rows
that never moved. See ``users/migrations/0001_initial.py``.
"""

from django.contrib.auth.base_user import AbstractBaseUser, BaseUserManager
from django.contrib.auth.models import Group, Permission, PermissionsMixin
from django.db import models
from django.utils import timezone


class UserManager(BaseUserManager):
    # The migration that adopts auth_user needs create_superuser at times.
    use_in_migrations = True

    def _create_user(self, email, password, **extra_fields):
        if not email:
            raise ValueError('An email address is required.')
        # normalize_email only lowercases the domain; the whole address is
        # lowercased here so that the unique constraint and the __iexact
        # lookups in accounts.identity agree on what counts as one account.
        email = self.normalize_email(email).strip().lower()
        user = self.model(email=email, **extra_fields)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_user(self, email=None, password=None, **extra_fields):
        extra_fields.setdefault('is_staff', False)
        extra_fields.setdefault('is_superuser', False)
        return self._create_user(email, password, **extra_fields)

    def create_superuser(self, email=None, password=None, **extra_fields):
        extra_fields.setdefault('is_staff', True)
        extra_fields.setdefault('is_superuser', True)

        if extra_fields.get('is_staff') is not True:
            raise ValueError('A superuser must have is_staff=True.')
        if extra_fields.get('is_superuser') is not True:
            raise ValueError('A superuser must have is_superuser=True.')

        return self._create_user(email, password, **extra_fields)

    def get_by_natural_key(self, username):
        # Addresses are stored lowercased, but a sign-in form is free to send
        # any casing, so the lookup that ModelBackend runs is case-insensitive.
        return self.get(**{f'{self.model.USERNAME_FIELD}__iexact': username})


class User(AbstractBaseUser, PermissionsMixin):
    email = models.EmailField('email address', max_length=254, unique=True)
    is_staff = models.BooleanField(
        'staff status',
        default=False,
        help_text='Designates whether the user can log into this admin site.',
    )
    is_active = models.BooleanField(
        'active',
        default=True,
        help_text=(
            'Designates whether this account should be treated as active. '
            'Unselect this instead of deleting accounts.'
        ),
    )
    date_joined = models.DateTimeField('date joined', default=timezone.now)

    # Overridden purely to keep the join tables where they already are; the
    # definitions otherwise match PermissionsMixin's.
    groups = models.ManyToManyField(
        Group,
        verbose_name='groups',
        blank=True,
        related_name='user_set',
        related_query_name='user',
        db_table='auth_user_groups',
        help_text=(
            'The groups this user belongs to. A user will get all permissions '
            'granted to each of their groups.'
        ),
    )
    user_permissions = models.ManyToManyField(
        Permission,
        verbose_name='user permissions',
        blank=True,
        related_name='user_set',
        related_query_name='user',
        db_table='auth_user_user_permissions',
        help_text='Specific permissions for this user.',
    )

    objects = UserManager()

    USERNAME_FIELD = 'email'
    EMAIL_FIELD = 'email'
    REQUIRED_FIELDS = []

    class Meta:
        db_table = 'auth_user'
        verbose_name = 'user'
        verbose_name_plural = 'users'

    def __str__(self):
        return self.email

    def clean(self):
        super().clean()
        self.email = self.__class__.objects.normalize_email(self.email).strip().lower()
