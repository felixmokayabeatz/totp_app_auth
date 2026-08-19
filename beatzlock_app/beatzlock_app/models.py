from django.contrib.auth.models import User
from django.core.validators import FileExtensionValidator, MaxValueValidator, MinValueValidator
from django.core.files.storage import default_storage
from django.db import models, transaction
from django.db.models import F, Q
from django.utils import timezone
import os
import posixpath
import re


def delete_existing_app_file(upload_folder, filename):
    file_path = posixpath.join(upload_folder, filename)
    try:
        if default_storage.exists(file_path):
            default_storage.delete(file_path)
    except Exception:
        pass


def delete_existing_files_in_folder(upload_folder):
    try:
        dirnames, filenames = default_storage.listdir(upload_folder)
    except Exception:
        return

    for filename in filenames:
        try:
            default_storage.delete(posixpath.join(upload_folder, filename))
        except Exception:
            pass

    for dirname in dirnames:
        delete_existing_files_in_folder(posixpath.join(upload_folder, dirname))


def app_upload_path(instance, filename):
    """
    Binary files land at:
      downloads/apps/YYYY/MM/DD/<platform-or-linux-distro>/<filename>
    """
    now = timezone.now()
    upload_folder = posixpath.join(
        'downloads', 'apps',
        str(now.year), f"{now.month:02d}", f"{now.day:02d}",
        instance.build_target_slug,
    )
    delete_existing_app_file(upload_folder, filename)
    return posixpath.join(upload_folder, filename)


def release_notes_upload_path(instance, filename):
    """
    Release-notes .txt files land at:
      downloads/release_notes/v<version>/<filename>
    Name the file after the version, e.g. v1.2.3.txt
    One file covers all platforms for that release.
    """
    upload_folder = posixpath.join(
        'downloads', 'release_notes',
        f"v{instance.version}",
    )
    delete_existing_files_in_folder(upload_folder)
    return posixpath.join(upload_folder, filename)


def _parse_semver_key(version):
    parts = [part.strip() for part in str(version or '').split('.') if part.strip()]
    numbers = []

    for part in parts[:3]:
        match = re.match(r'\d+', part)
        numbers.append(int(match.group(0)) if match else 0)

    while len(numbers) < 3:
        numbers.append(0)

    return tuple(numbers[:3])


def _parse_build_key(build_number):
    match = re.search(r'\d+', str(build_number or ''))
    return int(match.group(0)) if match else 0


def release_sort_key_from_app(app):
    released_at = app.release.released_at.timestamp() if app.release and app.release.released_at else 0
    return (
        *_parse_semver_key(app.version),
        _parse_build_key(app.build_number),
        released_at,
        app.id or 0,
    )


class AppRelease(models.Model):
    version = models.CharField(
        max_length=20,
        unique=True,
        help_text="Semantic version shared across all platforms, e.g. 1.2.3",
    )
    build_number = models.CharField(
        max_length=40,
        blank=True,
        help_text="Internal build identifier, e.g. 20250425 or build-47. Optional.",
    )
    release_notes_file = models.FileField(
        upload_to=release_notes_upload_path,
        validators=[FileExtensionValidator(allowed_extensions=['txt'])],
        blank=True,
        null=True,
        help_text=(
            "Plain-text (.txt) release notes for this version — covers all platforms. "
            "Name the file after the version, e.g. v1.2.3.txt. "
            "All line breaks and blank lines in the file are preserved on the front end."
        ),
    )
    released_at = models.DateTimeField(
        default=timezone.now,
        help_text="Date this version was publicly released.",
    )
    is_major_release = models.BooleanField(
        default=False,
        help_text="Mark important major releases so they can be found in the older versions page.",
    )
    keep_in_archive = models.BooleanField(
        default=False,
        help_text="Protect this release from automatic cleanup and show it on the older versions page.",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-released_at']
        verbose_name = "App Release"
        verbose_name_plural = "App Releases"

    def __str__(self):
        build = f" (build {self.build_number})" if self.build_number else ""
        return f"v{self.version}{build}"

    def save(self, *args, **kwargs):
        old_file_name = ''
        if self.pk:
            try:
                old_file_name = (
                    type(self)
                    .objects.only('release_notes_file')
                    .get(pk=self.pk)
                    .release_notes_file.name
                )
            except type(self).DoesNotExist:
                old_file_name = ''

        super().save(*args, **kwargs)

        current_file_name = self.release_notes_file.name if self.release_notes_file else ''
        if old_file_name and old_file_name != current_file_name:
            try:
                storage = self._meta.get_field('release_notes_file').storage
                if storage.exists(old_file_name):
                    storage.delete(old_file_name)
            except Exception:
                pass

    def delete(self, *args, **kwargs):
        file_field = self.release_notes_file
        storage = file_field.storage if file_field else None
        file_name = file_field.name if file_field else ''
        super().delete(*args, **kwargs)
        if file_name and storage and storage.exists(file_name):
            storage.delete(file_name)

    @property
    def release_notes_text(self):
        """Read and return the release notes text. Newlines preserved."""
        if not self.release_notes_file:
            return ""
        try:
            self.release_notes_file.open('rb')
            raw = self.release_notes_file.read()
            self.release_notes_file.close()
            return raw.decode('utf-8', errors='replace')
        except Exception:
            return ""


class DownloadableApp(models.Model):
    KEEP_CURRENT_PER_PLATFORM = 1
    KEEP_ARCHIVE_FALLBACK_PER_PLATFORM = 2
    DEFAULT_LINUX_DISTRIBUTION = 'ubuntu'

    PLATFORM_CHOICES = [
        ('windows', 'Windows (EXE)'),
        ('android', 'Android (APK)'),
        ('linux', 'Linux'),
        ('macos', 'macOS'),
        ('ios', 'iOS'),
    ]

    LINUX_DISTRIBUTION_CHOICES = [
        ('ubuntu', 'Ubuntu / Debian (.deb)'),
        ('kali', 'Kali Linux (.deb)'),
        ('fedora', 'Fedora (.rpm)'),
        ('debian', 'Debian (.deb)'),
        ('arch', 'Arch Linux'),
        ('opensuse', 'openSUSE'),
        ('manjaro', 'Manjaro'),
    ]

    name = models.CharField(max_length=100, default="BeatzLock Authenticator")
    platform = models.CharField(max_length=20, choices=PLATFORM_CHOICES)
    linux_distribution = models.CharField(
        max_length=30,
        choices=LINUX_DISTRIBUTION_CHOICES,
        blank=True,
        default='',
        db_index=True,
        help_text=(
            "Linux builds only. Existing generic Linux builds are treated as "
            "Ubuntu / Debian unless you choose another distro."
        ),
    )
    release = models.ForeignKey(
        AppRelease,
        on_delete=models.PROTECT,
        related_name='platform_builds',
        null=True,
        blank=True,
        help_text="Select the release (version) this binary belongs to.",
    )
    file = models.FileField(
        upload_to=app_upload_path,
        validators=[FileExtensionValidator(
            allowed_extensions=['exe', 'apk', 'deb', 'rpm', 'dmg', 'pkg', 'ipa']
        )],
    )
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']
        verbose_name = "Platform Build"
        verbose_name_plural = "Platform Builds"

    @classmethod
    def linux_distribution_values(cls):
        return [value for value, _ in cls.LINUX_DISTRIBUTION_CHOICES]

    @classmethod
    def linux_distribution_label(cls, value):
        labels = dict(cls.LINUX_DISTRIBUTION_CHOICES)
        return labels.get(value, str(value or '').title())

    @classmethod
    def normalized_linux_distribution_value(cls, value):
        value = str(value or '').strip().lower()
        if value in cls.linux_distribution_values():
            return value
        return cls.DEFAULT_LINUX_DISTRIBUTION

    @classmethod
    def infer_linux_distribution_from_filename(cls, filename):
        extension = os.path.splitext(str(filename or ''))[1].lower()
        if extension == '.rpm':
            return 'fedora'
        return cls.DEFAULT_LINUX_DISTRIBUTION

    @classmethod
    def build_target_slug_for(cls, platform, linux_distribution=''):
        if platform == 'linux':
            distro = cls.normalized_linux_distribution_value(linux_distribution)
            return f"linux-{distro}"
        return platform

    @classmethod
    def build_target_filter(cls, platform, linux_distribution=''):
        filters = Q(platform=platform)
        if platform == 'linux':
            distro = cls.normalized_linux_distribution_value(linux_distribution)
            if distro == cls.DEFAULT_LINUX_DISTRIBUTION:
                filters &= Q(linux_distribution=distro) | Q(linux_distribution='')
            else:
                filters &= Q(linux_distribution=distro)
        return filters

    @property
    def normalized_linux_distribution(self):
        if self.platform != 'linux':
            return ''
        return self.normalized_linux_distribution_value(self.linux_distribution)

    @property
    def build_target_slug(self):
        return self.build_target_slug_for(self.platform, self.linux_distribution)

    @property
    def build_target_key(self):
        if self.platform == 'linux':
            return self.build_target_slug
        return self.platform

    @property
    def download_target_display(self):
        if self.platform == 'linux':
            return self.linux_distribution_label(self.normalized_linux_distribution)
        return self.get_platform_display()

    def __str__(self):
        release_version = self.release.version if self.release else "unassigned"
        return f"{self.name} - {self.download_target_display} v{release_version}"

    def save(self, *args, **kwargs):
        if self.platform == 'linux' and not self.linux_distribution:
            self.linux_distribution = self.infer_linux_distribution_from_filename(self.file.name)
        elif self.platform != 'linux':
            self.linux_distribution = ''

        super().save(*args, **kwargs)
        self.prune_old_builds_for_platform(self.platform, self.linux_distribution)

    @classmethod
    def retained_builds_for_platform(cls, platform, linux_distribution=''):
        all_builds = list(
            cls.objects.filter(
                cls.build_target_filter(platform, linux_distribution),
                release__isnull=False,
            )
            .select_related('release')
        )
        all_builds.sort(key=release_sort_key_from_app, reverse=True)

        current_release_ids = []
        fallback_archive_release_ids = []
        retained_builds = []

        for build in all_builds:
            if build.release.keep_in_archive or build.release.is_major_release:
                retained_builds.append(build)
                continue
            if not build.is_active:
                continue
            if (
                build.release_id not in current_release_ids
                and len(current_release_ids) < cls.KEEP_CURRENT_PER_PLATFORM
            ):
                current_release_ids.append(build.release_id)
                retained_builds.append(build)
                continue
            if (
                build.release_id not in current_release_ids
                and build.release_id not in fallback_archive_release_ids
                and len(fallback_archive_release_ids) < cls.KEEP_ARCHIVE_FALLBACK_PER_PLATFORM
            ):
                fallback_archive_release_ids.append(build.release_id)
                retained_builds.append(build)

        return retained_builds

    @classmethod
    def prune_old_builds_for_platform(cls, platform, linux_distribution=''):
        builds = list(
            cls.objects.filter(
                cls.build_target_filter(platform, linux_distribution),
                release__isnull=False,
            )
            .select_related('release')
        )
        builds.sort(key=release_sort_key_from_app, reverse=True)
        retained_ids = {
            build.id for build in cls.retained_builds_for_platform(platform, linux_distribution)
        }
        removable_builds = []
        seen_file_names = set()

        for build in builds:
            file_name = build.file.name if build.file else ''
            if file_name and file_name in seen_file_names:
                removable_builds.append(build)
                continue
            if file_name:
                seen_file_names.add(file_name)
            if build.id in retained_ids:
                continue
            removable_builds.append(build)

        for build in removable_builds:
            build.delete()

        cls.cleanup_unretained_files_for_platform(platform, linux_distribution)

    @classmethod
    def cleanup_unretained_files_for_platform(cls, platform, linux_distribution=''):
        retained_files = {
            build.file.name
            for build in cls.retained_builds_for_platform(platform, linux_distribution)
            if build.file and build.file.name
        }
        target_slug = cls.build_target_slug_for(platform, linux_distribution)
        base_folder = posixpath.join('downloads', 'apps')

        def cleanup_folder(folder):
            try:
                dirnames, filenames = default_storage.listdir(folder)
            except Exception:
                return

            if folder.endswith(f'/{target_slug}'):
                for filename in filenames:
                    file_path = posixpath.join(folder, filename)
                    if file_path not in retained_files:
                        try:
                            default_storage.delete(file_path)
                        except Exception:
                            pass
                return

            for dirname in dirnames:
                cleanup_folder(posixpath.join(folder, dirname))

        cleanup_folder(base_folder)
        cls.delete_empty_app_directories()

    @classmethod
    def delete_empty_app_directories(cls):
        try:
            base_path = default_storage.path(posixpath.join('downloads', 'apps'))
        except Exception:
            return

        if not os.path.isdir(base_path):
            return

        for dirpath, dirnames, filenames in os.walk(base_path, topdown=False):
            if dirpath == base_path:
                continue
            if dirnames or filenames:
                continue
            try:
                os.rmdir(dirpath)
            except OSError:
                pass

    def delete(self, *args, **kwargs):
        file_field = self.file
        storage = file_field.storage if file_field else None
        file_name = file_field.name if file_field else ''
        has_other_reference = False
        if file_name:
            has_other_reference = type(self).objects.filter(file=file_name).exclude(pk=self.pk).exists()
        super().delete(*args, **kwargs)
        if file_name and storage and not has_other_reference and storage.exists(file_name):
            storage.delete(file_name)

    @property
    def version(self):
        return self.release.version if self.release else ""

    @property
    def build_number(self):
        return self.release.build_number if self.release else ""

    @property
    def release_notes_text(self):
        return self.release.release_notes_text if self.release else ""

    @property
    def has_release_notes(self):
        return bool(self.release and self.release.release_notes_file)

    @property
    def file_size(self):
        try:
            if self.file and self.file.storage.exists(self.file.name):
                size_bytes = self.file.storage.size(self.file.name)
                for unit in ['B', 'KB', 'MB', 'GB']:
                    if size_bytes < 1024.0:
                        return f"{size_bytes:.1f} {unit}"
                    size_bytes /= 1024.0
        except Exception:
            pass
        return "Unknown size"

    @property
    def clean_filename(self):
        ext = os.path.splitext(self.file.name)[1]
        safe_name = self.name.replace(' ', '-')
        version = self.version or 'unknown'
        return f"{safe_name}-{self.build_target_slug}-v{version}{ext}"


class LegalPage(models.Model):
    PAGE_CHOICES = [
        ('terms', 'Terms of Service'),
        ('privacy', 'Privacy Policy'),
    ]

    page_type = models.CharField(max_length=20, choices=PAGE_CHOICES, unique=True)
    title = models.CharField(max_length=200)
    content = models.TextField(
        help_text=(
            "Write using the TinyMCE rich-text editor. "
            "Headings, lists, links, tables and colours are all rendered on the front end."
        )
    )
    last_updated = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Legal Page"
        verbose_name_plural = "Legal Pages"

    def __str__(self):
        return self.get_page_type_display()


class AppRating(models.Model):
    PLATFORM_CHOICES = DownloadableApp.PLATFORM_CHOICES + [('unknown', 'Unknown')]

    platform = models.CharField(
        max_length=20,
        choices=PLATFORM_CHOICES,
        default='unknown',
        db_index=True,
    )
    reviewer_key = models.CharField(
        max_length=64,
        null=True,
        blank=True,
        db_index=True,
        help_text='Hashed app-user key used to keep one rating per user per platform.',
    )
    platform_history = models.CharField(
        max_length=240,
        blank=True,
        default='',
        help_text='Ordered platform slugs this user has submitted or edited from.',
    )
    platform_reviews = models.JSONField(
        blank=True,
        default=dict,
        help_text='Per-platform review payloads stored inside a single user review record.',
    )
    display_name = models.CharField(max_length=80, blank=True, default='')
    stars = models.PositiveSmallIntegerField(
        validators=[MinValueValidator(1), MaxValueValidator(5)]
    )
    comment = models.TextField(blank=True, default='')
    suggestion = models.TextField(blank=True, default='')
    app_version = models.CharField(max_length=40, blank=True, default='')
    build_number = models.CharField(max_length=40, blank=True, default='')
    device_label = models.CharField(max_length=160, blank=True, default='')
    account_user_id = models.CharField(max_length=40, blank=True, default='')
    account_email = models.EmailField(blank=True, default='')
    account_username = models.CharField(max_length=150, blank=True, default='')
    admin_reply = models.TextField(blank=True, default='')
    admin_reply_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='beatzlock_review_replies',
    )
    admin_replied_at = models.DateTimeField(null=True, blank=True)
    admin_reply_sent_at = models.DateTimeField(null=True, blank=True)
    useful_count = models.PositiveIntegerField(default=0)
    is_approved = models.BooleanField(
        default=True,
        help_text='Uncheck to hide this review from the public ratings page.',
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']
        verbose_name = 'App Rating'
        verbose_name_plural = 'App Ratings'
        constraints = [
            models.UniqueConstraint(
                fields=['reviewer_key'],
                name='unique_app_rating_per_user',
            ),
        ]

    def __str__(self):
        return f"{self.stars}/5 - {self.platform_label}"

    @property
    def platform_label(self):
        return dict(self.PLATFORM_CHOICES).get(self.platform, self.platform.title())

    @property
    def platform_values(self):
        reviews = self.platform_reviews if isinstance(self.platform_reviews, dict) else {}
        ordered = []
        history = [value for value in (self.platform_history or '').strip('|').split('|') if value]

        for value in history:
            normalized = self.normalize_platform(value)
            if normalized in reviews and normalized not in ordered:
                ordered.append(normalized)

        for value in reviews.keys():
            normalized = self.normalize_platform(value)
            if normalized not in ordered:
                ordered.append(normalized)

        if ordered:
            return ordered

        return [self.normalize_platform(self.platform)]

    @property
    def platform_display_list(self):
        labels = [self.platform_label_for(value) for value in self.platform_values]
        return ', '.join(labels)

    @property
    def display_name_or_anonymous(self):
        return self.display_name.strip() or 'Anonymous user'

    @classmethod
    def valid_platforms(cls):
        return {value for value, _ in cls.PLATFORM_CHOICES}

    @classmethod
    def normalize_platform(cls, platform):
        return platform if platform in cls.valid_platforms() else 'unknown'

    @classmethod
    def platform_label_for(cls, platform):
        normalized = cls.normalize_platform(platform)
        return dict(cls.PLATFORM_CHOICES).get(normalized, normalized.title())

    def add_platform(self, platform):
        platform = self.normalize_platform(platform)
        ordered = [value for value in (self.platform_history or '').strip('|').split('|') if value]
        if platform in ordered:
            ordered = [value for value in ordered if value != platform]
        ordered.append(platform)
        self.platform = platform
        self.platform_history = '|' + '|'.join(ordered) + '|'

    def get_platform_review(self, platform):
        normalized = self.normalize_platform(platform)
        reviews = self.platform_reviews if isinstance(self.platform_reviews, dict) else {}
        entry = reviews.get(normalized)
        if isinstance(entry, dict):
            return dict(entry)

        if not reviews and normalized == self.normalize_platform(self.platform):
            return {
                'platform': normalized,
                'stars': self.stars,
                'comment': self.comment,
                'suggestion': self.suggestion,
                'app_version': self.app_version,
                'build_number': self.build_number,
                'device_label': self.device_label,
                'created_at': self.created_at.isoformat() if self.created_at else None,
                'updated_at': self.updated_at.isoformat() if self.updated_at else None,
                'admin_reply': self.admin_reply,
                'admin_replied_at': self.admin_replied_at.isoformat() if self.admin_replied_at else None,
                'admin_reply_sent_at': self.admin_reply_sent_at.isoformat() if self.admin_reply_sent_at else None,
                'useful_count': self.useful_count,
            }
        return None

    def set_platform_review(self, platform, payload):
        normalized = self.normalize_platform(platform)
        reviews = dict(self.platform_reviews or {})
        reviews[normalized] = dict(payload)
        self.platform_reviews = reviews
        self.add_platform(normalized)

    def remove_platform_review(self, platform):
        normalized = self.normalize_platform(platform)
        reviews = dict(self.platform_reviews or {})
        reviews.pop(normalized, None)
        self.platform_reviews = reviews

        ordered = [value for value in (self.platform_history or '').strip('|').split('|') if value]
        ordered = [value for value in ordered if self.normalize_platform(value) != normalized]

        remaining = []
        for value in ordered:
            item = self.normalize_platform(value)
            if item in reviews and item not in remaining:
                remaining.append(item)
        for value in reviews.keys():
            item = self.normalize_platform(value)
            if item not in remaining:
                remaining.append(item)

        if remaining:
            self.platform = remaining[-1]
            self.platform_history = '|' + '|'.join(remaining) + '|'
        else:
            self.platform = 'unknown'
            self.platform_history = ''

    def sync_summary_fields(self, active_platform=''):
        reviews = self.platform_reviews if isinstance(self.platform_reviews, dict) else {}
        if not reviews:
            return

        def sort_key(item):
            entry = item[1] if isinstance(item[1], dict) else {}
            return entry.get('updated_at') or entry.get('created_at') or ''

        platform = self.normalize_platform(active_platform)
        if platform and platform in reviews:
            selected_platform, selected = platform, reviews[platform]
        else:
            selected_platform, selected = max(reviews.items(), key=sort_key)

        selected = dict(selected or {})
        self.platform = selected_platform
        self.stars = int(selected.get('stars') or self.stars or 1)
        self.comment = str(selected.get('comment') or '')
        self.suggestion = str(selected.get('suggestion') or '')
        self.app_version = str(selected.get('app_version') or '')
        self.build_number = str(selected.get('build_number') or '')
        self.device_label = str(selected.get('device_label') or '')
        self.admin_reply = str(selected.get('admin_reply') or '')

        total_useful = 0
        selected_reply_at = selected.get('admin_replied_at') or None
        selected_reply_sent_at = selected.get('admin_reply_sent_at') or None
        for entry in reviews.values():
            if not isinstance(entry, dict):
                continue
            total_useful += int(entry.get('useful_count') or 0)

        self.useful_count = total_useful
        self.admin_replied_at = timezone.datetime.fromisoformat(selected_reply_at) if selected_reply_at else None
        self.admin_reply_sent_at = (
            timezone.datetime.fromisoformat(selected_reply_sent_at)
            if selected_reply_sent_at else None
        )


class AppRatingUsefulVote(models.Model):
    rating = models.ForeignKey(
        AppRating,
        on_delete=models.CASCADE,
        related_name='useful_votes',
    )
    platform = models.CharField(max_length=20, default='unknown', db_index=True)
    voter_key = models.CharField(max_length=64, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ['rating', 'platform', 'voter_key']
        verbose_name = 'Rating Useful Vote'
        verbose_name_plural = 'Rating Useful Votes'

    def __str__(self):
        return f"Useful vote for rating #{self.rating_id}"

class DownloadStats(models.Model):
    """One row per app and country, with an accumulated download count."""

    app = models.ForeignKey(DownloadableApp, on_delete=models.CASCADE, related_name='stats')
    country_code = models.CharField(max_length=10, db_index=True)
    country_name = models.CharField(max_length=100)
    download_count = models.PositiveIntegerField(default=0)
    last_downloaded = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ['app', 'country_code']
        ordering = ['-download_count', '-last_downloaded', 'country_name']
        verbose_name_plural = "Download Statistics"

    def __str__(self):
        return f"{self.app} - {self.country_name}: {self.download_count}"

    @classmethod
    def record_download(cls, app, country_code, country_name, download_date=None, recorded_at=None):
        now = recorded_at or timezone.now()
        download_day = download_date or timezone.localdate()

        with transaction.atomic():
            stats, _ = cls.objects.select_for_update().get_or_create(
                app=app,
                country_code=country_code,
                defaults={
                    'country_name': country_name,
                    'download_count': 0,
                    'last_downloaded': now,
                },
            )
            cls.objects.filter(pk=stats.pk).update(
                country_name=country_name,
                download_count=F('download_count') + 1,
                last_downloaded=now,
            )
            DownloadDailyStat._record_download_locked(
                app=app,
                country_code=country_code,
                country_name=country_name,
                download_date=download_day,
                recorded_at=now,
            )

        return cls.objects.get(pk=stats.pk)


class DownloadDailyStat(models.Model):
    """One row per app, country, and day for timeline reporting."""

    app = models.ForeignKey(DownloadableApp, on_delete=models.CASCADE, related_name='daily_stats')
    country_code = models.CharField(max_length=10, db_index=True)
    country_name = models.CharField(max_length=100)
    download_date = models.DateField(db_index=True)
    download_count = models.PositiveIntegerField(default=0)
    last_downloaded = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ['app', 'country_code', 'download_date']
        ordering = ['-download_date', '-download_count', 'country_name']
        verbose_name = "Daily Download Statistic"
        verbose_name_plural = "Daily Download Statistics"

    def __str__(self):
        return f"{self.app} - {self.country_name} on {self.download_date}: {self.download_count}"

    @classmethod
    def _record_download_locked(cls, app, country_code, country_name, download_date, recorded_at):
        daily_stat, _ = cls.objects.select_for_update().get_or_create(
            app=app,
            country_code=country_code,
            download_date=download_date,
            defaults={
                'country_name': country_name,
                'download_count': 0,
                'last_downloaded': recorded_at,
            },
        )
        cls.objects.filter(pk=daily_stat.pk).update(
            country_name=country_name,
            download_count=F('download_count') + 1,
            last_downloaded=recorded_at,
        )
        return cls.objects.get(pk=daily_stat.pk)

    @classmethod
    def record_download(cls, app, country_code, country_name, download_date=None, recorded_at=None):
        now = recorded_at or timezone.now()
        download_day = download_date or timezone.localdate()

        with transaction.atomic():
            return cls._record_download_locked(
                app=app,
                country_code=country_code,
                country_name=country_name,
                download_date=download_day,
                recorded_at=now,
            )


class TotalDownloadCount(models.Model):
    """Single-row global download counter."""

    total_downloads = models.PositiveIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"Total Downloads: {self.total_downloads}"

    @classmethod
    def get_total(cls):
        obj, _ = cls.objects.get_or_create(id=1)
        return obj.total_downloads

    @classmethod
    def increment(cls, amount=1):
        with transaction.atomic():
            obj, _ = cls.objects.select_for_update().get_or_create(
                id=1,
                defaults={'total_downloads': 0},
            )
            cls.objects.filter(pk=obj.pk).update(
                total_downloads=F('total_downloads') + amount,
                updated_at=timezone.now(),
            )

        obj.refresh_from_db(fields=['total_downloads', 'updated_at'])
        return obj.total_downloads
