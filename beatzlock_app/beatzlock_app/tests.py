from datetime import datetime, timedelta, timezone as dt_timezone
from unittest import mock
from urllib.parse import parse_qs, urlparse

from django.core import mail
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.files.base import ContentFile
from django.contrib.auth import get_user_model
from django.conf import settings
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import Client, RequestFactory, SimpleTestCase, TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
import io
import json
import os
import re
import shutil
import tempfile
import uuid

from django.contrib.admin.sites import AdminSite
from django.contrib.messages.storage.fallback import FallbackStorage

from .admin import LegalPageAdmin
from .models import AppRating, AppRelease, DownloadDailyStat, DownloadStats, DownloadableApp, LegalPage, TotalDownloadCount, profile_for
from . import google_auth
from .admin import StaffChangeForm, StaffCreationForm
from .review_replies import dispatch_review_reply
from console.download_stats import build_download_stats_context
from .views import _group_ratings_for_display, _parse_build_number, submit_rating, update_check


def _workspace_temp_dir(prefix='beatzlock-test-'):
    root = os.path.join(settings.BASE_DIR, '.tmp_test_media')
    os.makedirs(root, exist_ok=True)
    path = os.path.join(root, f'{prefix}{uuid.uuid4().hex}')
    os.makedirs(path, exist_ok=True)
    return path


class _FakeApp:
    def __init__(self, platform, version, build_number, app_id=1):
        self.platform = platform
        self.version = version
        self.build_number = build_number
        self.id = app_id
        self.release = type('Release', (), {'released_at': None})()
        self.release_notes_text = 'Bug fixes'


class UpdateRuleTests(SimpleTestCase):
    def test_build_number_parser_handles_plain_numeric_values(self):
        self.assertEqual(_parse_build_number('2'), 2)

    def test_build_number_parser_handles_prefixed_values(self):
        self.assertEqual(_parse_build_number('build-47'), 47)


class AppRatingTests(TestCase):
    def setUp(self):
        self.factory = RequestFactory()

    def _submit_rating(self, reviewer_key, platform, display_name=''):
        request = self.factory.post(
            '/api/ratings/submit/',
            data=json.dumps({
                'reviewer_key': reviewer_key,
                'platform': platform,
                'display_name': display_name,
                'stars': 5,
                'comment': 'Solid app',
                'account_user_id': '42',
                'account_email': 'felix@example.com',
                'account_username': 'felix',
            }),
            content_type='application/json',
        )
        return submit_rating(request)

    def test_same_user_gets_one_review_per_platform(self):
        self._submit_rating('same-user', 'android', display_name='Felix')
        self._submit_rating('same-user', 'windows', display_name='Felix')

        rating = AppRating.objects.get()
        self.assertEqual(AppRating.objects.count(), 1)
        self.assertEqual(rating.platform_values, ['android', 'windows'])
        self.assertEqual(set(rating.platform_reviews.keys()), {'android', 'windows'})

    def test_same_user_edit_updates_only_that_platform_review(self):
        self._submit_rating('same-user', 'android', display_name='Felix')
        self._submit_rating('same-user', 'windows', display_name='Felix')
        request = self.factory.post(
            '/api/ratings/submit/',
            data=json.dumps({
                'reviewer_key': 'same-user',
                'platform': 'android',
                'display_name': 'Felix',
                'stars': 3,
                'comment': 'Needs work',
            }),
            content_type='application/json',
        )
        submit_rating(request)

        rating = AppRating.objects.get()
        self.assertEqual(AppRating.objects.count(), 1)
        self.assertEqual(rating.get_platform_review('android')['comment'], 'Needs work')
        self.assertEqual(rating.get_platform_review('android')['stars'], 3)
        self.assertEqual(rating.get_platform_review('windows')['comment'], 'Solid app')

    def test_blank_display_name_falls_back_to_anonymous_user(self):
        self._submit_rating('anonymous-user', 'android')

        rating = AppRating.objects.get()
        self.assertEqual(rating.display_name, '')
        self.assertEqual(rating.display_name_or_anonymous, 'Anonymous user')

    def test_delete_rating_removes_only_selected_platform(self):
        self._submit_rating('same-user', 'android', display_name='Felix')
        self._submit_rating('same-user', 'windows', display_name='Felix')

        response = self.client.post(
            reverse('beatzlock_app:delete_rating'),
            data=json.dumps({
                'reviewer_key': 'same-user',
                'platform': 'windows',
            }),
            content_type='application/json',
        )

        rating = AppRating.objects.get()
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()['deleted'])
        self.assertEqual(rating.platform_values, ['android'])
        self.assertIsNone(rating.get_platform_review('windows'))


@override_settings(
    EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend',
    DEFAULT_FROM_EMAIL='noreply@example.com',
    SUPPORT_EMAIL='info@example.com',
    BEATZLOCK_API_BASE_URL='https://api.example.com/api/',
    BEATZLOCK_INTERNAL_SERVICE_SECRET='shared-secret',
)
class ReviewReplyDispatchTests(TestCase):
    @mock.patch('beatzlock_app.review_replies.requests.post')
    def test_dispatch_review_reply_sends_email_and_app_notification(self, mock_post):
        mock_post.return_value.raise_for_status.return_value = None
        rating = AppRating.objects.create(
            reviewer_key='reply-user',
            platform='android',
            display_name='Felix',
            stars=5,
            comment='Nice app',
            account_user_id='88',
            account_email='felix@example.com',
            account_username='felix',
            admin_reply='Thanks for the feedback.',
            platform_reviews={
                'android': {
                    'platform': 'android',
                    'stars': 5,
                    'comment': 'Nice app',
                    'suggestion': '',
                    'app_version': '',
                    'build_number': '',
                    'device_label': '',
                    'created_at': timezone.now().isoformat(),
                    'updated_at': timezone.now().isoformat(),
                    'admin_reply': 'Thanks for the feedback.',
                    'admin_replied_at': timezone.now().isoformat(),
                    'admin_reply_sent_at': None,
                    'useful_count': 0,
                }
            },
            platform_history='|android|',
        )

        result = dispatch_review_reply(rating, platform='android', entry=rating.get_platform_review('android'))

        self.assertTrue(result['email_sent'])
        self.assertTrue(result['notification_sent'])
        self.assertEqual(len(mail.outbox), 1)
        self.assertIn('Thanks for the feedback.', mail.outbox[0].body)
        self.assertEqual(mail.outbox[0].reply_to, ['info@example.com'])
        self.assertEqual(len(mail.outbox[0].alternatives), 1)
        self.assertEqual(mail.outbox[0].alternatives[0].mimetype, 'text/html')
        self.assertIn('BeatzLock Authenticator reply', mail.outbox[0].alternatives[0].content)
        mock_post.assert_called_once()
        self.assertEqual(
            mock_post.call_args.args[0],
            'https://api.example.com/api/external/review-reply/',
        )



class RatingGroupingTests(TestCase):
    def test_grouping_keeps_one_card_per_user_with_platform_tabs(self):
        rating = AppRating.objects.create(
            reviewer_key='same-user',
            platform='linux',
            display_name='Felix',
            stars=5,
            comment='Linux review',
            platform_history='|linux|android|',
            platform_reviews={
                'linux': {
                    'platform': 'linux',
                    'stars': 5,
                    'comment': 'Linux review',
                    'suggestion': '',
                    'app_version': '',
                    'build_number': '',
                    'device_label': '',
                    'created_at': timezone.now().isoformat(),
                    'updated_at': timezone.now().isoformat(),
                    'admin_reply': '',
                    'admin_replied_at': None,
                    'admin_reply_sent_at': None,
                    'useful_count': 0,
                },
                'android': {
                    'platform': 'android',
                    'stars': 4,
                    'comment': 'Android review',
                    'suggestion': '',
                    'app_version': '',
                    'build_number': '',
                    'device_label': '',
                    'created_at': timezone.now().isoformat(),
                    'updated_at': timezone.now().isoformat(),
                    'admin_reply': '',
                    'admin_replied_at': None,
                    'admin_reply_sent_at': None,
                    'useful_count': 0,
                },
            },
        )

        groups = _group_ratings_for_display([rating], 'linux')

        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['active_platform'], 'linux')
        self.assertEqual(len(groups[0]['entries']), 2)


class RatingUsefulVoteTests(TestCase):
    def test_same_browser_can_only_vote_once_per_platform(self):
        now_iso = timezone.now().isoformat()
        rating = AppRating.objects.create(
            reviewer_key='same-user',
            platform='android',
            display_name='Felix',
            stars=5,
            comment='Nice app',
            platform_history='|android|windows|',
            platform_reviews={
                'android': {
                    'platform': 'android',
                    'stars': 5,
                    'comment': 'Nice app',
                    'suggestion': '',
                    'app_version': '',
                    'build_number': '',
                    'device_label': '',
                    'created_at': now_iso,
                    'updated_at': now_iso,
                    'admin_reply': '',
                    'admin_replied_at': None,
                    'admin_reply_sent_at': None,
                    'useful_count': 0,
                },
                'windows': {
                    'platform': 'windows',
                    'stars': 4,
                    'comment': 'Windows app',
                    'suggestion': '',
                    'app_version': '',
                    'build_number': '',
                    'device_label': '',
                    'created_at': now_iso,
                    'updated_at': now_iso,
                    'admin_reply': '',
                    'admin_replied_at': None,
                    'admin_reply_sent_at': None,
                    'useful_count': 0,
                },
            },
        )

        url = reverse('beatzlock_app:mark_rating_useful', args=[rating.pk])
        response = self.client.post(url, {'platform': 'android'}, HTTP_ACCEPT='application/json')
        second = self.client.post(url, {'platform': 'android'}, HTTP_ACCEPT='application/json')
        other_platform = self.client.post(url, {'platform': 'windows'}, HTTP_ACCEPT='application/json')

        rating.refresh_from_db()
        self.assertEqual(response.json()['useful_count'], 1)
        self.assertFalse(second.json()['created'])
        self.assertEqual(other_platform.json()['useful_count'], 1)
        self.assertEqual(rating.get_platform_review('android')['useful_count'], 1)
        self.assertEqual(rating.get_platform_review('windows')['useful_count'], 1)


class ReviewRepliesToolTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_superuser(
            username='admin',
            email='admin@example.com',
            password='password123',
        )

    @mock.patch('console.review_replies.dispatch_review_reply')
    def test_reply_tool_saves_platform_reply_without_redirecting_to_django_admin(self, mock_dispatch):
        mock_dispatch.return_value = {
            'email_sent': True,
            'notification_sent': True,
            'errors': [],
        }
        now_iso = timezone.now().isoformat()
        rating = AppRating.objects.create(
            reviewer_key='reply-user',
            platform='android',
            display_name='Felix',
            stars=5,
            comment='Nice app',
            account_user_id='88',
            account_email='felix@example.com',
            platform_history='|android|',
            platform_reviews={
                'android': {
                    'platform': 'android',
                    'stars': 5,
                    'comment': 'Nice app',
                    'suggestion': '',
                    'app_version': '',
                    'build_number': '',
                    'device_label': '',
                    'created_at': now_iso,
                    'updated_at': now_iso,
                    'admin_reply': '',
                    'admin_replied_at': None,
                    'admin_reply_sent_at': None,
                    'useful_count': 0,
                }
            },
        )

        self.client.force_login(self.user)
        response = self.client.post(
            reverse('review_replies'),
            {
                'rating_id': rating.pk,
                'platform': 'android',
                'admin_reply': 'Thanks for the review.',
                'next': reverse('review_replies'),
            },
        )

        rating.refresh_from_db()
        entry = rating.get_platform_review('android')
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response.url, reverse('review_replies'))
        self.assertEqual(entry['admin_reply'], 'Thanks for the review.')
        self.assertIsNotNone(entry['admin_reply_sent_at'])
        mock_dispatch.assert_called_once()

    def test_reply_tool_can_delete_platform_reply(self):
        now_iso = timezone.now().isoformat()
        rating = AppRating.objects.create(
            reviewer_key='reply-user',
            platform='android',
            display_name='Felix',
            stars=5,
            comment='Nice app',
            account_user_id='88',
            account_email='felix@example.com',
            platform_history='|android|',
            platform_reviews={
                'android': {
                    'platform': 'android',
                    'stars': 5,
                    'comment': 'Nice app',
                    'suggestion': '',
                    'app_version': '',
                    'build_number': '',
                    'device_label': '',
                    'created_at': now_iso,
                    'updated_at': now_iso,
                    'admin_reply': 'Old reply',
                    'admin_replied_at': now_iso,
                    'admin_reply_sent_at': now_iso,
                    'useful_count': 0,
                }
            },
        )

        self.client.force_login(self.user)
        response = self.client.post(
            reverse('review_replies'),
            {
                'rating_id': rating.pk,
                'platform': 'android',
                'action': 'delete_reply',
                'next': reverse('review_replies'),
            },
        )

        rating.refresh_from_db()
        entry = rating.get_platform_review('android')
        self.assertEqual(response.status_code, 302)
        self.assertEqual(entry['admin_reply'], '')
        self.assertIsNone(entry['admin_reply_sent_at'])


class DownloadStatsAggregationTests(TestCase):
    def setUp(self):
        self.app = DownloadableApp.objects.create(
            name='BeatzLock Authenticator',
            platform='android',
            file=SimpleUploadedFile('beatzlock.apk', b'apk-binary'),
        )

    def test_record_download_keeps_one_row_per_country(self):
        DownloadStats.record_download(self.app, 'KE', 'Kenya')
        DownloadStats.record_download(self.app, 'KE', 'Kenya')

        stats = DownloadStats.objects.get(app=self.app, country_code='KE')
        self.assertEqual(DownloadStats.objects.count(), 1)
        self.assertEqual(stats.download_count, 2)

    def test_record_download_also_tracks_daily_totals(self):
        tracked_day = timezone.localdate() - timedelta(days=2)
        DownloadStats.record_download(self.app, 'KE', 'Kenya', download_date=tracked_day)
        DownloadStats.record_download(self.app, 'KE', 'Kenya', download_date=tracked_day)

        daily_stat = DownloadDailyStat.objects.get(
            app=self.app,
            country_code='KE',
            download_date=tracked_day,
        )
        self.assertEqual(DownloadDailyStat.objects.count(), 1)
        self.assertEqual(daily_stat.download_count, 2)

    def test_total_download_counter_increments(self):
        total = TotalDownloadCount.increment()
        total = TotalDownloadCount.increment()

        self.assertEqual(total, 2)
        self.assertEqual(TotalDownloadCount.get_total(), 2)


class DownloadStatsPageContextTests(TestCase):
    def setUp(self):
        self.media_root = _workspace_temp_dir()
        self.override = override_settings(MEDIA_ROOT=self.media_root)
        self.override.enable()

    def tearDown(self):
        self.override.disable()
        shutil.rmtree(self.media_root, ignore_errors=True)

    def _create_build(self, version, platform='android'):
        release = AppRelease.objects.create(version=version, released_at=timezone.now())
        return DownloadableApp.objects.create(
            name='BeatzLock Authenticator',
            platform=platform,
            release=release,
            file=SimpleUploadedFile(f'beatzlock-{platform}-{version}.apk', b'apk-binary'),
        )

    def test_current_and_archived_downloads_are_counted_separately_by_platform(self):
        archived = self._create_build('1.0.0')
        current = self._create_build('2.0.0')
        today = timezone.localdate()

        DownloadStats.record_download(archived, 'KE', 'Kenya', download_date=today - timedelta(days=5))
        DownloadStats.record_download(archived, 'KE', 'Kenya', download_date=today - timedelta(days=5))
        DownloadStats.record_download(archived, 'US', 'United States', download_date=today - timedelta(days=2))
        DownloadStats.record_download(current, 'KE', 'Kenya', download_date=today - timedelta(days=1))
        DownloadStats.record_download(current, 'KE', 'Kenya', download_date=today - timedelta(days=1))
        DownloadStats.record_download(current, 'KE', 'Kenya', download_date=today)

        context = build_download_stats_context()

        self.assertEqual(context['total_downloads_all'], 3)
        self.assertEqual(context['archived_downloads_all'], 3)
        self.assertEqual(len(context['app_stats']), 1)
        self.assertEqual(len(context['archived_app_stats']), 1)
        self.assertEqual(context['app_stats'][0]['platform'], 'android')
        self.assertEqual(context['app_stats'][0]['total_downloads'], 3)
        self.assertEqual(context['archived_app_stats'][0]['platform'], 'android')
        self.assertEqual(context['archived_app_stats'][0]['total_downloads'], 3)
        self.assertEqual(context['top_countries'][0]['country_code'], 'KE')
        self.assertEqual(context['top_countries'][0]['total'], 3)
        self.assertEqual(len(context['timeline_labels']), 30)
        self.assertEqual(sum(context['timeline_current_points']), 3)
        self.assertEqual(sum(context['timeline_archived_points']), 3)
        self.assertTrue(context['timeline_has_data'])

    def test_context_applies_custom_range_country_filter_and_country_sort(self):
        archived = self._create_build('3.0.0')
        current = self._create_build('4.0.0')
        today = timezone.localdate()

        DownloadStats.record_download(current, 'KE', 'Kenya', download_date=today - timedelta(days=3))
        DownloadStats.record_download(current, 'KE', 'Kenya', download_date=today - timedelta(days=1))
        DownloadStats.record_download(current, 'US', 'United States', download_date=today - timedelta(days=1))
        DownloadStats.record_download(archived, 'US', 'United States', download_date=today - timedelta(days=2))

        request = RequestFactory().get(
            '/console/stats/',
            {
                'range': 'custom',
                'start_date': (today - timedelta(days=3)).isoformat(),
                'end_date': (today - timedelta(days=1)).isoformat(),
                'country': 'KE',
                'country_sort': 'country_asc',
            },
        )

        context = build_download_stats_context(request)

        self.assertEqual(context['selected_range'], 'custom')
        self.assertEqual(context['selected_country_code'], 'KE')
        self.assertEqual(context['country_sort'], 'country_asc')
        self.assertEqual(context['start_date'], today - timedelta(days=3))
        self.assertEqual(context['end_date'], today - timedelta(days=1))
        self.assertEqual(context['timeline_current_total'], 2)
        self.assertEqual(context['timeline_archived_total'], 0)
        self.assertEqual(context['timeline_current_points'], [1, 0, 1])
        self.assertEqual(context['timeline_archived_points'], [0, 0, 0])


class DownloadListViewTests(TestCase):
    def setUp(self):
        self.media_root = _workspace_temp_dir()
        self.override = override_settings(MEDIA_ROOT=self.media_root)
        self.override.enable()

    def tearDown(self):
        self.override.disable()
        shutil.rmtree(self.media_root, ignore_errors=True)

    def _create_build(self, version, platform='android', linux_distribution=''):
        release = AppRelease.objects.create(version=version, released_at=timezone.now())
        extension = 'apk'
        if platform == 'linux':
            extension = 'rpm' if linux_distribution == 'fedora' else 'deb'
        return DownloadableApp.objects.create(
            name='BeatzLock Authenticator',
            platform=platform,
            linux_distribution=linux_distribution,
            release=release,
            file=SimpleUploadedFile(f'beatzlock-{platform}-{version}.{extension}', b'app-binary'),
        )

    def test_download_list_only_shows_uploaded_linux_distributions(self):
        self._create_build('1.0.0', platform='linux', linux_distribution='ubuntu')
        self._create_build('2.0.0', platform='linux', linux_distribution='fedora')

        response = self.client.get(reverse('beatzlock_app:download_list'))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            [option['value'] for option in response.context['linux_distribution_options']],
            ['ubuntu', 'fedora'],
        )
        self.assertContains(response, 'Ubuntu / Debian (.deb)')
        self.assertContains(response, 'Fedora (.rpm)')
        self.assertNotContains(response, 'Kali Linux (.deb)')
        self.assertNotContains(response, 'Build slot reserved for a future release.')
        self.assertNotContains(response, 'Coming Soon')
        self.assertNotContains(response, 'More later')


class DownloadableAppRetentionTests(TestCase):
    def setUp(self):
        self.media_root = _workspace_temp_dir()
        self.override = override_settings(MEDIA_ROOT=self.media_root)
        self.override.enable()

    def tearDown(self):
        self.override.disable()
        shutil.rmtree(self.media_root, ignore_errors=True)

    def _create_build(
        self,
        version,
        platform='android',
        linux_distribution='',
        keep_in_archive=False,
        is_major_release=False,
    ):
        release = AppRelease.objects.create(
            version=version,
            released_at=timezone.now(),
            keep_in_archive=keep_in_archive,
            is_major_release=is_major_release,
        )
        extension = 'apk'
        if platform == 'linux':
            extension = 'rpm' if linux_distribution == 'fedora' else 'deb'
        return DownloadableApp.objects.create(
            name='BeatzLock Authenticator',
            platform=platform,
            linux_distribution=linux_distribution,
            release=release,
            file=SimpleUploadedFile(f'beatzlock-{version}.{extension}', b'app-binary'),
        )

    def test_new_upload_keeps_current_build_and_two_archive_fallbacks_per_platform(self):
        for version in ['1.0.0', '1.1.0', '1.2.0', '1.3.0', '1.4.0']:
            self._create_build(version)

        versions = set(
            DownloadableApp.objects.filter(platform='android')
            .select_related('release')
            .values_list('release__version', flat=True)
        )

        self.assertEqual(versions, {'1.2.0', '1.3.0', '1.4.0'})

    def test_archived_or_major_builds_are_protected_from_cleanup(self):
        self._create_build('1.0.0', keep_in_archive=True)
        for version in ['1.1.0', '1.2.0', '1.3.0', '1.4.0']:
            self._create_build(version)

        versions = set(
            DownloadableApp.objects.filter(platform='android')
            .select_related('release')
            .values_list('release__version', flat=True)
        )

        self.assertEqual(versions, {'1.0.0', '1.2.0', '1.3.0', '1.4.0'})

    def test_same_day_same_filename_replaces_existing_file_without_random_suffix(self):
        first_release = AppRelease.objects.create(version='2.0.0', released_at=timezone.now())
        first_app = DownloadableApp.objects.create(
            name='BeatzLock Authenticator',
            platform='android',
            release=first_release,
            file=SimpleUploadedFile('beatzlock.apk', b'old-apk'),
        )

        second_release = AppRelease.objects.create(version='2.1.0', released_at=timezone.now())
        second_app = DownloadableApp.objects.create(
            name='BeatzLock Authenticator',
            platform='android',
            release=second_release,
            file=SimpleUploadedFile('beatzlock.apk', b'new-apk'),
        )

        self.assertEqual(second_app.file.name.rsplit('/', 1)[-1], 'beatzlock.apk')
        self.assertFalse(DownloadableApp.objects.filter(pk=first_app.pk).exists())
        folder = second_app.file.name.rsplit('/', 1)[0]
        _, filenames = second_app.file.storage.listdir(folder)
        self.assertEqual(filenames, ['beatzlock.apk'])
        with second_app.file.storage.open(second_app.file.name, 'rb') as uploaded_file:
            self.assertEqual(uploaded_file.read(), b'new-apk')

    def test_upload_removes_old_orphan_files_for_same_platform_across_months(self):
        old_file = 'downloads/apps/2026/01/10/android/old.apk'
        other_platform_file = 'downloads/apps/2026/01/10/windows/old.exe'

        storage = DownloadableApp._meta.get_field('file').storage
        storage.save(old_file, ContentFile(b'old-android'))
        storage.save(other_platform_file, ContentFile(b'old-windows'))

        self._create_build('3.0.0', platform='android')

        self.assertFalse(storage.exists(old_file))
        self.assertTrue(storage.exists(other_platform_file))

    def test_linux_distribution_builds_are_retained_separately(self):
        for version in ['1.0.0', '1.1.0', '1.2.0', '1.3.0', '1.4.0']:
            self._create_build(version, platform='linux', linux_distribution='ubuntu')

        fedora = self._create_build('2.0.0', platform='linux', linux_distribution='fedora')

        ubuntu_versions = set(
            DownloadableApp.objects.filter(platform='linux', linux_distribution='ubuntu')
            .select_related('release')
            .values_list('release__version', flat=True)
        )

        self.assertEqual(ubuntu_versions, {'1.2.0', '1.3.0', '1.4.0'})
        self.assertTrue(DownloadableApp.objects.filter(pk=fedora.pk).exists())

    def test_linux_rpm_upload_without_distribution_defaults_to_fedora(self):
        release = AppRelease.objects.create(version='5.0.0', released_at=timezone.now())
        app = DownloadableApp.objects.create(
            name='BeatzLock Authenticator',
            platform='linux',
            release=release,
            file=SimpleUploadedFile('beatzlock-fedora.rpm', b'rpm-binary'),
        )

        self.assertEqual(app.linux_distribution, 'fedora')
        self.assertIn('/linux-fedora/', app.file.name)

    def test_update_check_can_target_linux_distribution(self):
        self.factory = RequestFactory()
        self._create_build('1.0.0', platform='linux', linux_distribution='ubuntu')
        self._create_build('2.0.0', platform='linux', linux_distribution='fedora')

        request = self.factory.get(
            '/api/update-check/',
            {
                'platform': 'linux',
                'distribution': 'fedora',
                'version': '1.0.0',
                'build_number': '0',
            },
        )
        response = update_check(request)
        payload = json.loads(response.content)

        self.assertEqual(payload['linux_distribution'], 'fedora')
        self.assertEqual(payload['latest_version'], '2.0.0')
        self.assertEqual(payload['platform_display'], 'Fedora (.rpm)')

    def test_file_size_uses_storage_size(self):
        app = self._create_build('4.0.0', platform='android')

        self.assertEqual(app.file_size, '10.0 B')


class AppReleaseNotesUploadTests(TestCase):
    def setUp(self):
        self.media_root = _workspace_temp_dir()
        self.override = override_settings(MEDIA_ROOT=self.media_root)
        self.override.enable()

    def tearDown(self):
        self.override.disable()
        shutil.rmtree(self.media_root, ignore_errors=True)

    def test_reuploading_same_version_replaces_existing_release_notes_file(self):
        release = AppRelease.objects.create(
            version='5.0.0',
            released_at=timezone.now(),
            release_notes_file=SimpleUploadedFile('v5.0.0.txt', b'old notes'),
        )

        release.release_notes_file = SimpleUploadedFile('v5.0.0.txt', b'updated notes')
        release.save()

        self.assertEqual(release.release_notes_file.name, 'downloads/release_notes/v5.0.0/v5.0.0.txt')
        folder = release.release_notes_file.name.rsplit('/', 1)[0]
        _, filenames = release.release_notes_file.storage.listdir(folder)
        self.assertEqual(filenames, ['v5.0.0.txt'])
        with release.release_notes_file.storage.open(release.release_notes_file.name, 'rb') as uploaded_file:
            self.assertEqual(uploaded_file.read(), b'updated notes')

    def test_reuploading_release_notes_clears_other_files_from_same_version_folder(self):
        release = AppRelease.objects.create(
            version='5.1.0',
            released_at=timezone.now(),
            release_notes_file=SimpleUploadedFile('old.txt', b'old notes'),
        )
        storage = release.release_notes_file.storage
        folder = release.release_notes_file.name.rsplit('/', 1)[0]
        storage.save(f'{folder}/stray.txt', ContentFile(b'stray'))

        release.release_notes_file = SimpleUploadedFile('fresh.txt', b'fresh notes')
        release.save()

        self.assertFalse(storage.exists(f'{folder}/old.txt'))
        self.assertFalse(storage.exists(f'{folder}/stray.txt'))
        self.assertEqual(release.release_notes_file.name, f'{folder}/fresh.txt')
        _, filenames = storage.listdir(folder)
        self.assertEqual(filenames, ['fresh.txt'])


class EmailAsLoginTests(TestCase):
    """The site has no usernames: the email address is the login."""

    password = 'Str0ng-Passw0rd!x'

    def _make_user(self, email, **extra):
        return get_user_model().objects.create_user(
            username=email, email=email, password=self.password, **extra
        )

    def test_createsuperuser_takes_an_email_and_asks_for_no_username(self):
        call_command(
            'createsuperuser',
            interactive=False,
            email='Deploy.Admin@Example.com',
            verbosity=0,
        )
        user = get_user_model().objects.get()
        self.assertTrue(user.is_superuser)
        self.assertEqual(user.email, 'deploy.admin@example.com')
        self.assertEqual(user.username, 'deploy.admin@example.com')

    def test_createsuperuser_refuses_an_address_already_in_use(self):
        self._make_user('taken@example.com')
        with self.assertRaises(CommandError):
            call_command(
                'createsuperuser',
                interactive=False,
                email='TAKEN@example.com',
                verbosity=0,
            )

    def test_sign_in_with_the_email_address_whatever_its_case(self):
        self._make_user('staff@example.com', is_staff=True)
        response = self.client.post(
            reverse('login'),
            {'username': 'STAFF@Example.com', 'password': self.password},
        )
        self.assertEqual(response.status_code, 302)
        self.assertIn('_auth_user_id', self.client.session)

    def test_sign_in_rejects_a_wrong_password_and_an_unknown_address(self):
        self._make_user('staff@example.com')
        for identifier, password in (
            ('staff@example.com', 'not-the-password'),
            ('nobody@example.com', self.password),
        ):
            with self.subTest(identifier=identifier):
                client = Client()
                client.post(
                    reverse('login'),
                    {'username': identifier, 'password': password},
                )
                self.assertNotIn('_auth_user_id', client.session)

    def test_legacy_account_with_a_separate_username_can_still_sign_in(self):
        get_user_model().objects.create_user(
            username='felixmokayabeatz',
            email='legacy@example.com',
            password=self.password,
        )
        for identifier in ('legacy@example.com', 'felixmokayabeatz'):
            with self.subTest(identifier=identifier):
                client = Client()
                client.post(
                    reverse('login'),
                    {'username': identifier, 'password': self.password},
                )
                self.assertIn('_auth_user_id', client.session)

    def test_login_links_to_the_password_reset_page(self):
        self.assertEqual(reverse('password_reset'), '/accounts/password_reset/')
        response = self.client.get(reverse('login'))
        self.assertContains(response, reverse('password_reset'))

    @override_settings(
        EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend',
        DEFAULT_FROM_EMAIL='Felixmokayabeatz <noreply@example.com>',
        SUPPORT_EMAIL='support@example.com',
    )
    def test_password_reset_sends_an_email_to_the_account_address(self):
        self._make_user('reset@example.com')
        response = self.client.post(
            reverse('password_reset'), {'email': 'RESET@Example.com'}
        )

        self.assertRedirects(response, reverse('password_reset_done'))
        self.assertEqual(len(mail.outbox), 1)
        message = mail.outbox[0]
        self.assertEqual(message.to, ['reset@example.com'])
        self.assertEqual(message.from_email, 'Felixmokayabeatz <noreply@example.com>')
        self.assertEqual(message.reply_to, ['support@example.com'])
        self.assertEqual(message.subject, 'Reset your Felixmokayabeatz password')
        self.assertIn('BeatzLock Apps account', message.body)
        self.assertIn('/accounts/reset/', message.body)
        self.assertEqual(len(message.alternatives), 1)
        self.assertEqual(message.alternatives[0].mimetype, 'text/html')
        self.assertIn('Reset password</a>', message.alternatives[0].content)

    @override_settings(
        EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend',
        DEFAULT_FROM_EMAIL='Felixmokayabeatz <noreply@example.com>',
    )
    def test_password_reset_sends_for_a_google_only_account(self):
        user = get_user_model().objects.create_user(
            username='google-only@example.com',
            email='google-only@example.com',
        )
        user.set_unusable_password()
        user.save()

        self.client.post(reverse('password_reset'), {'email': 'google-only@example.com'})

        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(mail.outbox[0].to, ['google-only@example.com'])

    @override_settings(
        EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend',
        DEFAULT_FROM_EMAIL='Felixmokayabeatz <noreply@example.com>',
    )
    def test_password_reset_link_sets_a_new_password(self):
        user = self._make_user('reset-me@example.com')
        self.client.post(reverse('password_reset'), {'email': 'reset-me@example.com'})
        link = re.search(
            r'https?://[^/]+(?P<path>/accounts/reset/\S+)', mail.outbox[0].body
        ).group('path')

        response = self.client.get(link)
        self.assertEqual(response.status_code, 302)
        response = self.client.post(response['Location'], {
            'new_password1': 'New-Str0ng-Passw0rd!x',
            'new_password2': 'New-Str0ng-Passw0rd!x',
        })
        user.refresh_from_db()

        self.assertRedirects(response, reverse('password_reset_complete'))
        self.assertTrue(user.check_password('New-Str0ng-Passw0rd!x'))
        fresh = Client()
        fresh.post(reverse('login'), {
            'username': 'reset-me@example.com',
            'password': 'New-Str0ng-Passw0rd!x',
        })
        self.assertIn('_auth_user_id', fresh.session)

    def test_the_admin_add_form_asks_for_an_email_and_writes_both_columns(self):
        form = StaffCreationForm(data={
            'email': 'New.Staff@Example.com',
            'password1': self.password,
            'password2': self.password,
        })
        self.assertNotIn('username', form.fields)
        self.assertTrue(form.is_valid(), form.errors)
        user = form.save()
        self.assertEqual(user.email, 'new.staff@example.com')
        self.assertEqual(user.username, 'new.staff@example.com')

    def test_changing_the_address_in_the_admin_moves_the_username_with_it(self):
        user = self._make_user('before@example.com')
        form = StaffChangeForm(
            instance=user,
            data={
                'email': 'after@example.com',
                'first_name': '',
                'last_name': '',
                'is_active': True,
                'is_staff': False,
                'is_superuser': False,
                'date_joined': user.date_joined,
            },
        )
        self.assertTrue(form.is_valid(), form.errors)
        changed = form.save()
        self.assertEqual(changed.email, 'after@example.com')
        self.assertEqual(changed.username, 'after@example.com')


class _FakeGoogleResponse:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self):
        return None

    def json(self):
        return self._payload


@override_settings(GOOGLE_CLIENT_ID='fake-client-id', GOOGLE_CLIENT_SECRET='fake-secret')
class GoogleSignInTests(TestCase):
    """The OAuth flow, with Google's two endpoints stubbed."""

    def _begin(self, client=None):
        """Start the flow and hand back the state Google would echo."""
        client = client or Client()
        response = client.get(reverse('google_login'))
        query = parse_qs(urlparse(response['Location']).query)
        return client, response, query

    def _finish(self, client, state, userinfo):
        with mock.patch.object(
            google_auth.requests, 'post',
            return_value=_FakeGoogleResponse({'access_token': 'fake-token'}),
        ), mock.patch.object(
            google_auth.requests, 'get',
            return_value=_FakeGoogleResponse(userinfo),
        ):
            return client.get(
                reverse('google_callback'), {'code': 'good-code', 'state': state}
            )

    def test_login_redirects_to_google_without_leaking_the_secret(self):
        client, response, query = self._begin()
        self.assertEqual(response.status_code, 302)
        self.assertEqual(urlparse(response['Location']).netloc, 'accounts.google.com')
        self.assertEqual(query['scope'][0], 'openid email profile')
        self.assertEqual(query['response_type'][0], 'code')
        self.assertNotIn('client_secret', query)
        self.assertEqual(client.session['google_oauth_state'], query['state'][0])

    def test_callback_refuses_a_state_it_did_not_issue(self):
        client, _, _ = self._begin()
        response = client.get(
            reverse('google_callback'), {'code': 'x', 'state': 'not-the-state'}
        )
        self.assertRedirects(response, reverse('login'), fetch_redirect_response=False)
        self.assertNotIn('_auth_user_id', client.session)

    def test_a_new_google_user_gets_an_account_keyed_on_their_email(self):
        client, _, query = self._begin()
        response = self._finish(client, query['state'][0], {
            'sub': 'google-uid-1',
            'email': 'NewPerson@Example.com',
            'email_verified': True,
            'given_name': 'New',
            'family_name': 'Person',
            'picture': 'https://lh3.googleusercontent.com/fake',
        })

        user = get_user_model().objects.get(email='newperson@example.com')
        self.assertEqual(response.status_code, 302)
        self.assertIn('_auth_user_id', client.session)
        self.assertEqual(user.username, 'newperson@example.com')
        self.assertEqual((user.first_name, user.last_name), ('New', 'Person'))
        self.assertFalse(user.has_usable_password())

        profile = user.profile
        self.assertEqual(profile.google_sub, 'google-uid-1')
        self.assertEqual(profile.avatar_url, 'https://lh3.googleusercontent.com/fake')

    def test_an_unverified_google_email_is_refused(self):
        client, _, query = self._begin()
        response = self._finish(client, query['state'][0], {
            'sub': 'google-uid-2',
            'email': 'sneaky@example.com',
            'email_verified': False,
        })
        self.assertRedirects(response, reverse('login'), fetch_redirect_response=False)
        self.assertNotIn('_auth_user_id', client.session)
        self.assertFalse(
            get_user_model().objects.filter(email='sneaky@example.com').exists()
        )

    def test_signing_in_with_google_links_an_existing_account(self):
        existing = get_user_model().objects.create_user(
            username='existing@example.com',
            email='existing@example.com',
            password='Str0ng-Passw0rd!x',
        )
        client, _, query = self._begin()
        self._finish(client, query['state'][0], {
            'sub': 'google-uid-3',
            'email': 'existing@example.com',
            'email_verified': True,
        })

        self.assertEqual(
            get_user_model().objects.filter(email='existing@example.com').count(), 1
        )
        self.assertEqual(client.session['_auth_user_id'], str(existing.pk))
        existing.refresh_from_db()
        self.assertTrue(existing.has_usable_password())


@override_settings(GOOGLE_CLIENT_ID='', GOOGLE_CLIENT_SECRET='')
class GoogleSignInDisabledTests(TestCase):
    def test_the_routes_are_absent_when_no_credentials_are_configured(self):
        self.assertEqual(Client().get(reverse('google_login')).status_code, 404)


class AccountPageTests(TestCase):
    password = 'Str0ng-Passw0rd!x'

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username='acct@example.com',
            email='acct@example.com',
            password=self.password,
        )
        self.client.force_login(self.user)
        self.media_root = _workspace_temp_dir('beatzlock-avatars-')

    def tearDown(self):
        shutil.rmtree(self.media_root, ignore_errors=True)

    @staticmethod
    def _png(size=(120, 120)):
        from PIL import Image
        buffer = io.BytesIO()
        Image.new('RGB', size, (74, 158, 255)).save(buffer, format='PNG')
        return buffer.getvalue()

    def test_the_account_page_needs_a_login(self):
        client = Client()
        response = client.get(reverse('beatzlock_app:account'))
        self.assertEqual(response.status_code, 302)
        self.assertIn(reverse('login'), response['Location'])

    def test_saving_a_display_name(self):
        response = self.client.post(reverse('beatzlock_app:account'), {
            'first_name': 'Felix', 'last_name': 'Mokaya',
        })
        self.assertEqual(response.status_code, 302)
        self.user.refresh_from_db()
        self.assertEqual((self.user.first_name, self.user.last_name), ('Felix', 'Mokaya'))

    def test_uploading_and_removing_a_profile_image(self):
        with override_settings(MEDIA_ROOT=self.media_root):
            self.client.post(reverse('beatzlock_app:account'), {
                'first_name': '', 'last_name': '',
                'avatar': SimpleUploadedFile('me.png', self._png(), content_type='image/png'),
            })
            profile = self.user.profile
            profile.refresh_from_db()
            self.assertTrue(profile.avatar)
            self.assertTrue(
                profile.avatar.name.startswith(f'accounts/avatars/{self.user.pk}/')
            )

            self.client.post(reverse('beatzlock_app:account'), {'remove_avatar': '1'})
            profile.refresh_from_db()
            self.assertFalse(profile.avatar)

    def test_existing_profile_image_does_not_show_path_or_clear_checkbox(self):
        with override_settings(MEDIA_ROOT=self.media_root):
            self.client.post(reverse('beatzlock_app:account'), {
                'first_name': '', 'last_name': '',
                'avatar': SimpleUploadedFile('me.png', self._png(), content_type='image/png'),
            })
            response = self.client.get(reverse('beatzlock_app:account'))

        self.assertContains(response, 'Remove image')
        self.assertContains(response, 'type="file"')
        self.assertNotContains(response, 'Currently:')
        self.assertNotContains(response, 'Clear')
        self.assertNotContains(response, '>accounts/avatars/')

    def test_an_image_over_the_size_limit_is_refused(self):
        oversized = SimpleUploadedFile(
            'huge.png',
            self._png((2000, 2000)) + b'\0' * (2 * 1024 * 1024),
            content_type='image/png',
        )
        with override_settings(MEDIA_ROOT=self.media_root):
            response = self.client.post(reverse('beatzlock_app:account'), {
                'first_name': '', 'last_name': '', 'avatar': oversized,
            })
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'under 2MB')
        self.user.profile.refresh_from_db()
        self.assertFalse(self.user.profile.avatar)

    def test_initials_stand_in_for_a_missing_picture(self):
        profile = profile_for(self.user)
        self.assertEqual(profile.initials, 'AE')
        self.user.first_name, self.user.last_name = 'Felix', 'Mokaya'
        self.user.save(update_fields=['first_name', 'last_name'])
        self.assertEqual(profile_for(self.user).initials, 'FM')


class SignUpTests(TestCase):
    """Two names, an email, a password. No confirmation step."""

    url = '/accounts/signup/'
    password = 'Str0ng-Passw0rd!x'

    def _payload(self, **overrides):
        payload = {
            'first_name': 'Brand',
            'last_name': 'New',
            'email': 'Brand.New@Example.com',
            'password1': self.password,
            'password2': self.password,
        }
        payload.update(overrides)
        return payload

    def test_the_form_asks_for_names_email_and_a_password(self):
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        for field in ('first_name', 'last_name', 'email', 'password1', 'password2'):
            self.assertContains(response, 'name="{}"'.format(field))

    def test_signing_up_creates_the_account_and_signs_straight_in(self):
        response = self.client.post(self.url, self._payload())
        user = get_user_model().objects.get(email='brand.new@example.com')

        self.assertEqual(response.status_code, 302)
        self.assertIn('_auth_user_id', self.client.session)
        self.assertEqual(user.username, 'brand.new@example.com')
        self.assertEqual((user.first_name, user.last_name), ('Brand', 'New'))
        self.assertTrue(user.check_password(self.password))

    def test_an_address_that_already_has_an_account_is_refused(self):
        get_user_model().objects.create_user(
            username='taken@example.com', email='taken@example.com', password=self.password
        )
        response = self.client.post(self.url, self._payload(email='TAKEN@example.com'))
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'already exists')
        self.assertEqual(
            get_user_model().objects.filter(email__iexact='taken@example.com').count(), 1
        )

    def test_a_mistyped_confirmation_creates_nothing(self):
        response = self.client.post(
            self.url, self._payload(password2='something-else!x')
        )
        self.assertEqual(response.status_code, 200)
        self.assertFalse(
            get_user_model().objects.filter(email='brand.new@example.com').exists()
        )

    def test_django_password_validators_still_apply(self):
        response = self.client.post(
            self.url, self._payload(password1='password', password2='password')
        )
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'too common')
        self.assertFalse(
            get_user_model().objects.filter(email='brand.new@example.com').exists()
        )

    def test_someone_already_signed_in_is_sent_to_their_account(self):
        user = get_user_model().objects.create_user(
            username='here@example.com', email='here@example.com', password=self.password
        )
        self.client.force_login(user)
        response = self.client.get(self.url)
        self.assertRedirects(
            response, reverse('beatzlock_app:account'), fetch_redirect_response=False
        )

    def test_the_two_pages_link_to_each_other(self):
        self.assertContains(self.client.get('/accounts/login/'), self.url)
        self.assertContains(self.client.get(self.url), reverse('login'))

    def test_signup_only_redirects_back_into_this_site(self):
        response = self.client.post(
            self.url + '?next=https://evil.example.com/', self._payload()
        )
        self.assertEqual(response['Location'], reverse('beatzlock_app:account'))


class AccountPasswordTests(TestCase):
    """Someone who arrived through Google can give themselves a password."""

    url = '/account/'
    new_password = 'Str0ng-Passw0rd!x'

    def _google_user(self):
        user = get_user_model().objects.create_user(
            username='googler@example.com', email='googler@example.com'
        )
        user.set_unusable_password()
        user.save()
        profile = profile_for(user)
        profile.google_sub = 'google-uid-9'
        profile.save(update_fields=['google_sub'])
        return user

    def test_a_google_user_is_offered_a_password_without_being_asked_for_one(self):
        self.client.force_login(self._google_user())
        response = self.client.get(self.url)
        self.assertContains(response, 'Set a password')
        self.assertContains(response, 'new_password1')
        self.assertNotContains(response, 'old_password')

    def test_setting_a_password_keeps_them_signed_in_and_adds_the_second_way_in(self):
        user = self._google_user()
        self.client.force_login(user)
        response = self.client.post(self.url, {
            'set_password': '1',
            'new_password1': self.new_password,
            'new_password2': self.new_password,
        })
        user.refresh_from_db()

        self.assertEqual(response.status_code, 302)
        self.assertTrue(user.has_usable_password())
        self.assertEqual(self.client.get(self.url).status_code, 200)
        self.assertEqual(profile_for(user).google_sub, 'google-uid-9')

        fresh = Client()
        fresh.post(reverse('login'), {
            'username': 'googler@example.com', 'password': self.new_password,
        })
        self.assertIn('_auth_user_id', fresh.session)

    def test_someone_with_a_password_must_give_the_old_one(self):
        user = get_user_model().objects.create_user(
            username='haspw@example.com', email='haspw@example.com', password='Old-Passw0rd!x'
        )
        self.client.force_login(user)
        response = self.client.get(self.url)
        self.assertContains(response, 'Change password')
        self.assertContains(response, 'old_password')

        response = self.client.post(self.url, {
            'set_password': '1',
            'old_password': 'not-the-old-one',
            'new_password1': self.new_password,
            'new_password2': self.new_password,
        })
        user.refresh_from_db()
        self.assertEqual(response.status_code, 200)
        self.assertTrue(user.check_password('Old-Passw0rd!x'))

        self.client.post(self.url, {
            'set_password': '1',
            'old_password': 'Old-Passw0rd!x',
            'new_password1': self.new_password,
            'new_password2': self.new_password,
        })
        user.refresh_from_db()
        self.assertTrue(user.check_password(self.new_password))

    def test_saving_details_does_not_disturb_the_password(self):
        user = get_user_model().objects.create_user(
            username='both@example.com', email='both@example.com', password='Old-Passw0rd!x'
        )
        self.client.force_login(user)
        response = self.client.post(self.url, {'first_name': 'Felix', 'last_name': 'Mokaya'})
        user.refresh_from_db()

        self.assertEqual(response.status_code, 302)
        self.assertEqual((user.first_name, user.last_name), ('Felix', 'Mokaya'))
        self.assertTrue(user.check_password('Old-Passw0rd!x'))


class LegalRevisionFlowTests(TestCase):
    def test_draft_is_invisible_everywhere(self):
        LegalPage.objects.create(
            page_type='terms', title='Terms of Service',
            app_version='1.8.0', content='<p>DRAFT BODY</p>',
        )
        self.assertIsNone(LegalPage.current('terms'))

        resp = self.client.get(reverse('beatzlock_app:legal_terms'))
        self.assertEqual(resp.status_code, 200)
        self.assertNotContains(resp, 'DRAFT BODY')
        self.assertContains(resp, 'Coming soon')

        api = self.client.get(reverse('beatzlock_app:legal_document_json', args=['terms']))
        self.assertTrue(api.json()['coming_soon'])
        self.assertNotIn('DRAFT BODY', api.json()['content_html'])

    def test_publishing_makes_it_live_and_stamps_date(self):
        page = LegalPage.objects.create(
            page_type='privacy', title='Privacy Policy',
            app_version='1.8.0', content='<p>V1 BODY</p>',
        )
        self.assertIsNone(page.published_at)

        page.is_published = True
        page.save()
        page.refresh_from_db()
        self.assertIsNotNone(page.published_at)

        resp = self.client.get(reverse('beatzlock_app:legal_privacy'))
        self.assertContains(resp, 'V1 BODY')

        api = self.client.get(reverse('beatzlock_app:legal_document_json', args=['privacy'])).json()
        self.assertFalse(api['coming_soon'])
        self.assertNotIn('app_version', api)
        self.assertNotIn('1.8.0', json.dumps(api))

    def test_new_revision_supersedes_and_old_one_stays_readable(self):
        v1 = LegalPage.objects.create(
            page_type='terms', title='Terms of Service', app_version='1.7.0',
            content='<p>V1 BODY</p>', is_published=True,
        )
        v2 = LegalPage.objects.create(
            page_type='terms', title='Terms of Service', app_version='1.8.0',
            content='<p>V2 BODY</p>', is_published=True,
        )

        self.assertEqual(LegalPage.current('terms').pk, v2.pk)
        self.assertEqual([r.pk for r in LegalPage.archive_for('terms')], [v1.pk])

        live = self.client.get(reverse('beatzlock_app:legal_terms'))
        self.assertContains(live, 'V2 BODY')
        self.assertNotContains(live, 'V1 BODY')
        self.assertContains(live, 'Previous versions of this document')

        archive = self.client.get(reverse('beatzlock_app:legal_terms_archive'))
        self.assertEqual(archive.status_code, 200)
        self.assertContains(archive, 'Current version')
        self.assertContains(archive, 'In effect until')

        old = self.client.get(reverse('beatzlock_app:legal_terms_revision', args=[v1.pk]))
        self.assertContains(old, 'V1 BODY')
        self.assertContains(old, 'This is an older version')

    def test_app_version_never_reaches_the_front_end(self):
        """It is an internal marker for the admin, not something users see."""
        LegalPage.objects.create(
            page_type='terms', title='Terms of Service', app_version='1.7.0',
            content='<p>V1 BODY</p>', is_published=True,
        )
        live = LegalPage.objects.create(
            page_type='terms', title='Terms of Service', app_version='1.8.0',
            content='<p>V2 BODY</p>', is_published=True,
        )
        old = LegalPage.objects.filter(app_version='1.7.0').get()

        for response in (
            self.client.get(reverse('beatzlock_app:legal_terms')),
            self.client.get(reverse('beatzlock_app:legal_terms_archive')),
            self.client.get(reverse('beatzlock_app:legal_terms_revision', args=[old.pk])),
            self.client.get(reverse('beatzlock_app:legal_document_json', args=['terms'])),
        ):
            body = response.content.decode()
            self.assertNotIn('1.8.0', body)
            self.assertNotIn('1.7.0', body)
            self.assertNotIn('App version', body)

        live.refresh_from_db()
        self.assertEqual(live.app_version, '1.8.0')

    def test_archive_url_rejects_drafts_and_wrong_document(self):
        draft = LegalPage.objects.create(
            page_type='terms', title='Terms of Service', content='<p>D</p>',
        )
        privacy = LegalPage.objects.create(
            page_type='privacy', title='Privacy Policy', content='<p>P</p>', is_published=True,
        )
        self.assertEqual(
            self.client.get(reverse('beatzlock_app:legal_terms_revision', args=[draft.pk])).status_code,
            404,
        )
        self.assertEqual(
            self.client.get(reverse('beatzlock_app:legal_terms_revision', args=[privacy.pk])).status_code,
            404,
        )

    def test_preview_is_staff_only(self):
        LegalPage.objects.create(
            page_type='terms', title='Terms of Service',
            content='<p>LIVE BODY</p>', is_published=True,
        )
        draft = LegalPage.objects.create(
            page_type='terms', title='Terms of Service', content='<p>SECRET DRAFT</p>',
        )
        url = reverse('beatzlock_app:legal_terms') + f'?preview={draft.pk}'

        anon = self.client.get(url)
        self.assertNotContains(anon, 'SECRET DRAFT')
        self.assertContains(anon, 'LIVE BODY')

        staff = get_user_model().objects.create_user('boss@example.com', 'boss@example.com', 'pw', is_staff=True)
        self.client.force_login(staff)
        seen = self.client.get(url)
        self.assertContains(seen, 'SECRET DRAFT')
        self.assertContains(seen, 'Staff preview')

    def test_unpublishing_falls_back_to_previous_revision(self):
        v1 = LegalPage.objects.create(
            page_type='terms', title='Terms of Service', content='<p>V1 BODY</p>', is_published=True,
        )
        v2 = LegalPage.objects.create(
            page_type='terms', title='Terms of Service', content='<p>V2 BODY</p>', is_published=True,
        )
        v2.is_published = False
        v2.save()
        self.assertEqual(LegalPage.current('terms').pk, v1.pk)
        self.assertContains(self.client.get(reverse('beatzlock_app:legal_terms')), 'V1 BODY')


class LegalPageAdminActionTests(TestCase):
    def setUp(self):
        self.admin = LegalPageAdmin(LegalPage, AdminSite())
        self.user = get_user_model().objects.create_superuser(
            'boss@example.com', 'boss@example.com', 'pw'
        )
        self.request = RequestFactory().get('/admin/')
        self.request.user = self.user
        setattr(self.request, 'session', {})
        setattr(self.request, '_messages', FallbackStorage(self.request))

    def test_duplicate_creates_independent_draft(self):
        live = LegalPage.objects.create(
            page_type='terms', title='Terms of Service', app_version='1.7.0',
            content='<p>V1</p>', is_published=True,
        )
        self.admin.duplicate_as_draft(self.request, LegalPage.objects.filter(pk=live.pk))

        self.assertEqual(LegalPage.objects.count(), 2)
        draft = LegalPage.objects.exclude(pk=live.pk).get()
        self.assertFalse(draft.is_published)
        self.assertIsNone(draft.published_at)
        self.assertEqual(draft.content, '<p>V1</p>')
        live.refresh_from_db()
        self.assertTrue(live.is_published)
        self.assertEqual(LegalPage.current('terms').pk, live.pk)

    def test_publish_action_stamps_and_supersedes(self):
        v1 = LegalPage.objects.create(
            page_type='terms', title='T', content='<p>V1</p>', is_published=True,
        )
        v2 = LegalPage.objects.create(page_type='terms', title='T', content='<p>V2</p>')
        self.admin.publish_revisions(self.request, LegalPage.objects.filter(pk=v2.pk))

        v2.refresh_from_db()
        self.assertTrue(v2.is_published)
        self.assertIsNotNone(v2.published_at)
        self.assertEqual(LegalPage.current('terms').pk, v2.pk)
        self.assertEqual([r.pk for r in LegalPage.archive_for('terms')], [v1.pk])

    def test_status_badge_reads_draft_live_archived(self):
        v1 = LegalPage.objects.create(
            page_type='terms', title='T', content='<p>1</p>', is_published=True,
        )
        v2 = LegalPage.objects.create(
            page_type='terms', title='T', content='<p>2</p>', is_published=True,
        )
        draft = LegalPage.objects.create(page_type='terms', title='T', content='<p>3</p>')
        self.assertIn('Draft', self.admin.status_badge(draft))
        self.assertIn('Live', self.admin.status_badge(v2))
        self.assertIn('Archived', self.admin.status_badge(v1))

    def test_live_links_render_after_save(self):
        page = LegalPage.objects.create(page_type='privacy', title='P', content='<p>x</p>')
        html = self.admin.live_links(page)
        self.assertIn(f'/legal/privacy-policy/?preview={page.pk}', html)
        self.assertIn('/legal/privacy-policy/archive/', html)
        self.assertIn('Save this revision first', self.admin.live_links(LegalPage()))


class LegalPageVersionDropdownTests(TestCase):
    def setUp(self):
        self.admin = LegalPageAdmin(LegalPage, AdminSite())
        self.request = RequestFactory().get('/admin/')
        self.request.user = get_user_model().objects.create_superuser(
            'boss@example.com', 'boss@example.com', 'pw'
        )
        self.field = LegalPage._meta.get_field('app_version')

    def _formfield(self, obj=None):
        self.request._legalpage_obj = obj
        return self.admin.formfield_for_dbfield(self.field, self.request)

    def test_lists_releases_newest_first_with_blank_option(self):
        now = timezone.now()
        AppRelease.objects.create(version='1.7.0', released_at=now - timedelta(days=40))
        AppRelease.objects.create(version='1.8.0', build_number='45', released_at=now)

        field = self._formfield()
        values = [value for value, _ in field.choices]
        self.assertEqual(values, ['', '1.8.0', '1.7.0'])
        labels = dict(field.choices)
        self.assertIn('build 45', labels['1.8.0'])
        self.assertFalse(field.required)

    def test_selecting_a_listed_version_validates(self):
        AppRelease.objects.create(version='1.8.0')
        field = self._formfield()
        self.assertEqual(field.clean('1.8.0'), '1.8.0')
        self.assertEqual(field.clean(''), '')
        with self.assertRaises(Exception):
            field.clean('9.9.9')

    def test_keeps_value_whose_release_row_was_deleted(self):
        AppRelease.objects.create(version='1.8.0')
        old = LegalPage.objects.create(
            page_type='terms', title='T', app_version='1.5.0',
            content='<p>x</p>', is_published=True,
        )
        field = self._formfield(obj=old)
        values = [value for value, _ in field.choices]
        self.assertIn('1.5.0', values)
        self.assertEqual(field.clean('1.5.0'), '1.5.0')
        self.assertIn('release record removed', dict(field.choices)['1.5.0'])

    def test_falls_back_to_text_input_when_no_releases_exist(self):
        field = self._formfield()
        self.assertFalse(hasattr(field, 'choices'))
        self.assertEqual(field.clean('2.0.0-beta'), '2.0.0-beta')

    def test_change_form_renders_a_select(self):
        AppRelease.objects.create(version='1.8.0')
        page = LegalPage.objects.create(page_type='terms', title='T', content='<p>x</p>')
        self.client.force_login(self.request.user)
        url = reverse('admin:beatzlock_app_legalpage_change', args=[page.pk])
        resp = self.client.get(url)
        self.assertEqual(resp.status_code, 200)
        html = resp.content.decode()
        self.assertIn('<select name="app_version"', html)
        self.assertIn('<option value="1.8.0">v1.8.0', html)
        self.assertIn('--- Not tied to a version ---', html)


class LegalTimestampFormatTests(TestCase):
    """Timestamps render in 24-hour form, in the site timezone, everywhere."""

    def _published(self, when, content):
        page = LegalPage.objects.create(
            page_type='terms', title='Terms of Service',
            content=content, is_published=True,
        )
        LegalPage.objects.filter(pk=page.pk).update(published_at=when)
        page.refresh_from_db()
        return page

    def test_afternoon_time_is_not_shown_as_12_hour(self):
        old = self._published(
            datetime(2026, 7, 19, 16, 45, tzinfo=dt_timezone.utc), '<p>V1</p>'
        )
        self._published(
            datetime(2026, 8, 28, 6, 7, tzinfo=dt_timezone.utc), '<p>V2</p>'
        )

        live = self.client.get(reverse('beatzlock_app:legal_terms'))
        self.assertContains(live, 'Last updated: August 28, 2026, 09:07 EAT')

        archived = self.client.get(
            reverse('beatzlock_app:legal_terms_revision', args=[old.pk])
        )
        self.assertContains(archived, 'Published: July 19, 2026, 19:45 EAT')

        archive = self.client.get(reverse('beatzlock_app:legal_terms_archive'))
        self.assertContains(archive, 'Published August 28, 2026, 09:07 EAT')
        self.assertContains(archive, 'Version of July 19, 2026, 19:45 EAT')
        self.assertContains(archive, 'In effect until August 28, 2026, 09:07 EAT')

        for resp in (live, archived, archive):
            body = resp.content.decode()
            self.assertNotIn('p.m.', body)
            self.assertNotIn('a.m.', body)

    def test_midnight_and_noon_stay_unambiguous(self):
        page = self._published(
            datetime(2026, 8, 27, 21, 0, tzinfo=dt_timezone.utc), '<p>midnight</p>'
        )
        resp = self.client.get(reverse('beatzlock_app:legal_terms'))
        self.assertContains(resp, 'August 28, 2026, 00:00 EAT')

        LegalPage.objects.filter(pk=page.pk).update(
            published_at=datetime(2026, 8, 28, 9, 0, tzinfo=dt_timezone.utc)
        )
        resp = self.client.get(reverse('beatzlock_app:legal_terms'))
        self.assertContains(resp, 'August 28, 2026, 12:00 EAT')

    def test_every_rendered_legal_timestamp_carries_a_time(self):
        old = self._published(
            datetime(2026, 7, 19, 16, 45, tzinfo=dt_timezone.utc), '<p>V1</p>'
        )
        self._published(
            datetime(2026, 8, 28, 6, 7, tzinfo=dt_timezone.utc), '<p>V2</p>'
        )
        bare_date = re.compile(
            r'(January|February|March|April|May|June|July|August|September|'
            r'October|November|December) \d{1,2}, \d{4}(?!, \d{2}:\d{2})'
        )
        for url in (
            reverse('beatzlock_app:legal_terms'),
            reverse('beatzlock_app:legal_terms_archive'),
            reverse('beatzlock_app:legal_terms_revision', args=[old.pk]),
        ):
            body = self.client.get(url).content.decode()
            self.assertIsNone(bare_date.search(body), f'date without a time on {url}')


class SitemapTests(TestCase):
    HOST = 'apps.example.com'

    def _locs(self):
        r = self.client.get('/sitemap.xml', HTTP_HOST=self.HOST, secure=True)
        self.assertEqual(r.status_code, 200)
        return re.findall(r'<loc>(.*?)</loc>', r.content.decode())

    def test_download_and_binary_urls_are_excluded(self):
        locs = self._locs()
        self.assertTrue(any(l.endswith('/downloads/') for l in locs))
        self.assertFalse([l for l in locs if '/download/' in l])
        self.assertFalse([l for l in locs if '/release-notes/' in l])
        self.assertFalse([l for l in locs if '/api/' in l])

    def test_unpublished_legal_is_not_listed(self):
        LegalPage.objects.create(page_type='terms', title='T', content='<p>d</p>')
        locs = self._locs()
        self.assertFalse([l for l in locs if 'terms-of-service' in l])

    def test_published_legal_and_archive_are_listed(self):
        LegalPage.objects.create(page_type='terms', title='T',
                                 content='<p>v1</p>', is_published=True)
        LegalPage.objects.create(page_type='terms', title='T',
                                 content='<p>v2</p>', is_published=True)
        locs = self._locs()
        self.assertIn(f'https://{self.HOST}/legal/terms-of-service/', locs)
        self.assertIn(f'https://{self.HOST}/legal/terms-of-service/archive/', locs)
        old = LegalPage.archive_for('terms')[0]
        self.assertNotIn(
            f'https://{self.HOST}/legal/terms-of-service/archive/{old.pk}/', locs)
        r = self.client.get(
            f'/legal/terms-of-service/archive/{old.pk}/',
            HTTP_HOST=self.HOST, secure=True)
        self.assertContains(r, 'noindex, follow')

    def test_robots_declares_the_sitemap(self):
        r = self.client.get('/robots.txt', HTTP_HOST=self.HOST, secure=True)
        self.assertEqual(r.status_code, 200)
        body = r.content.decode()
        self.assertIn(f'Sitemap: https://{self.HOST}/sitemap.xml', body)
        self.assertIn('Disallow: /download/', body)

    def test_all_sitemap_urls_resolve(self):
        LegalPage.objects.create(page_type='privacy', title='P',
                                 content='<p>x</p>', is_published=True)
        for loc in self._locs():
            path = loc.split(self.HOST, 1)[1]
            r = self.client.get(path, HTTP_HOST=self.HOST, secure=True)
            self.assertIn(r.status_code, (200, 301, 302),
                          f'{path} returned {r.status_code}')


class DownloadTargetGroupingTests(TestCase):
    """The download pages group builds in memory instead of per-target SQL.

    The pages used to ask the database once per platform and once per Linux
    distribution -- fourteen queries on the downloads page, twenty-six on the
    archive. They now read the table once and group in Python, so the Python
    filter has to agree with the SQL filter it replaced on every target.
    """

    @classmethod
    def setUpTestData(cls):
        from beatzlock_app.models import AppRelease, DownloadableApp

        cls.targets = [
            ('windows', ''),
            ('android', ''),
            ('macos', ''),
            ('ios', ''),
            ('linux', 'ubuntu'),
            ('linux', 'fedora'),
            ('linux', 'arch'),
            ('linux', ''),
        ]
        for index in range(3):
            release = AppRelease.objects.create(
                version=f'7.{index}.0',
                released_at=timezone.now() - timedelta(days=index),
                is_major_release=(index == 0),
                keep_in_archive=(index % 2 == 0),
            )
            for platform, distribution in cls.targets:
                DownloadableApp.objects.create(
                    name='BeatzLock',
                    platform=platform,
                    linux_distribution=distribution,
                    is_active=True,
                    release=release,
                )

    def test_the_python_filter_selects_what_the_sql_filter_selects(self):
        from beatzlock_app.models import DownloadableApp
        from beatzlock_app.views import _active_released_apps_for_target, _apps_for_target, _all_active_released_apps

        loaded = _all_active_released_apps()

        checked = 0
        for platform, _ in DownloadableApp.PLATFORM_CHOICES:
            distributions = (
                [value for value, _ in DownloadableApp.LINUX_DISTRIBUTION_CHOICES]
                if platform == 'linux'
                else ['']
            )
            for distribution in distributions:
                from_sql = {
                    app.id
                    for app in _active_released_apps_for_target(platform, distribution)
                }
                from_python = {
                    app.id for app in _apps_for_target(loaded, platform, distribution)
                }
                self.assertEqual(
                    from_sql,
                    from_python,
                    msg=f'{platform}/{distribution or "-"} disagreed',
                )
                checked += 1

        self.assertEqual(checked, 11)

    def test_a_build_saved_without_a_distribution_lands_in_the_default_group(self):
        from beatzlock_app.models import DownloadableApp
        from beatzlock_app.views import _all_active_released_apps, _apps_for_target

        blank_saved = DownloadableApp.objects.filter(
            platform='linux',
            linux_distribution=DownloadableApp.DEFAULT_LINUX_DISTRIBUTION,
        )
        self.assertTrue(blank_saved.exists())

        grouped = _apps_for_target(
            _all_active_released_apps(),
            'linux',
            DownloadableApp.DEFAULT_LINUX_DISTRIBUTION,
        )

        self.assertEqual(
            {app.id for app in grouped},
            set(blank_saved.values_list('id', flat=True)),
        )

    def test_the_downloads_page_reads_the_build_table_once(self):
        with self.assertNumQueries(4):
            response = self.client.get(reverse('beatzlock_app:download_list'))
        self.assertEqual(response.status_code, 200)

    def test_the_archive_page_reads_the_build_table_once(self):
        with self.assertNumQueries(1):
            response = self.client.get(reverse('beatzlock_app:archived_downloads'))
        self.assertEqual(response.status_code, 200)

    def test_the_latest_build_matches_what_a_per_target_query_would_pick(self):
        from beatzlock_app.views import (
            _active_released_apps_for_target,
            _all_active_released_apps,
            _latest_app_for_platform,
            _release_sort_key,
        )

        loaded = _all_active_released_apps()

        for platform, distribution in self.targets:
            with self.subTest(platform=platform, distribution=distribution):
                from_sql = sorted(
                    _active_released_apps_for_target(platform, distribution),
                    key=_release_sort_key,
                    reverse=True,
                )
                expected = from_sql[0] if from_sql else None
                actual = _latest_app_for_platform(platform, distribution, apps=loaded)

                self.assertEqual(
                    actual.id if actual else None,
                    expected.id if expected else None,
                )
