# beatzlock_app/views.py

from django.shortcuts import render, get_object_or_404, redirect
from django.http import Http404, JsonResponse
from django.views.decorators.cache import never_cache
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST
from django.core.cache import cache
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from .models import DownloadableApp, DownloadStats, TotalDownloadCount, LegalPage, AppRating, AppRatingUsefulVote, profile_for
from .forms import AccountForm, AvatarForm, SignUpForm
from .google_auth import google_enabled
from .utils.file_serving import x_accel_file_response
from django.conf import settings
from django.contrib import messages
from django.contrib.auth import login as auth_login, update_session_auth_hash
from django.contrib.auth.decorators import login_required
from django.contrib.auth.forms import PasswordChangeForm, SetPasswordForm
from django.urls import reverse
from django.db.models import Q
import os
import json
import hashlib
import re

# Shipped with this app, not with the project, so the app folder can be moved
# or copied without leaving its country database behind.
GEOIP_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data', 'GeoLite2-Country.mmdb')
PLATFORM_ORDER = ['windows', 'android', 'linux', 'macos', 'ios']
LINUX_DISTRO_ICONS = {
    'ubuntu': 'fab fa-ubuntu',
    'kali': 'fas fa-terminal',
    'fedora': 'fab fa-fedora',
    'debian': 'fab fa-linux',
    'arch': 'fas fa-cube',
    'opensuse': 'fab fa-linux',
    'manjaro': 'fas fa-layer-group',
}

if settings.DEBUG:
    print(f"DEBUG: GeoIP path set to: {GEOIP_PATH}")


def _parse_semver(version):
    parts = [part.strip() for part in str(version).split('.') if part.strip()]
    if not parts or len(parts) > 3:
        raise ValueError("Version must look like 1.0.1")

    try:
        numbers = [int(part) for part in parts]
    except ValueError as exc:
        raise ValueError("Version must contain only numbers separated by dots") from exc

    while len(numbers) < 3:
        numbers.append(0)

    return tuple(numbers[:3])


def _parse_build_number(build_number):
    raw = str(build_number or '').strip()
    if not raw:
        return 0

    match = re.search(r'\d+', raw)
    return int(match.group(0)) if match else 0


def _release_sort_key(app):
    released_at = app.release.released_at.timestamp() if app.release and app.release.released_at else 0
    return (
        *_parse_semver(app.version),
        _parse_build_number(app.build_number),
        released_at,
        app.id,
    )


def _build_update_payload(current_version, current_build_number, latest_app, request):
    latest_version = latest_app.version
    latest_build_number = _parse_build_number(latest_app.build_number)
    current_semver = _parse_semver(current_version)
    latest_semver = _parse_semver(latest_version)
    current_build_number = int(current_build_number)

    current_key = (*current_semver, current_build_number)
    latest_key = (*latest_semver, latest_build_number)

    update_available = latest_key > current_key
    force_update = False
    reason = 'You are already on the latest release.'

    if update_available:
        major_gap = latest_semver[0] - current_semver[0]
        minor_gap = latest_semver[1] - current_semver[1]
        patch_gap = latest_semver[2] - current_semver[2]
        build_gap = latest_build_number - current_build_number

        if major_gap > 0:
            force_update = True
            reason = 'A major update is required before you can keep using the app.'
        elif major_gap == 0 and minor_gap > 0:
            force_update = True
            reason = 'A minor update is required before you can keep using the app.'
        elif current_semver[:2] == latest_semver[:2] and patch_gap >= 5:
            force_update = True
            reason = 'Your app is five or more bug-fix releases behind and must be updated.'
        elif current_semver == latest_semver and build_gap >= 5:
            force_update = True
            reason = 'Your app build is five or more revisions behind and must be updated.'
        else:
            reason = 'A newer bug-fix update is available.'

    # Reversed, never written out: this app was mounted under /beatzlock-apps/
    # when it was part of the main site and now sits at the root of its own
    # subdomain. These two go out to the native clients as the update's
    # download link, so a stale prefix here is a dead button in the app.
    download_path = reverse('beatzlock_app:download_file', args=[latest_app.id])
    downloads_page_path = reverse('beatzlock_app:download_list')

    return {
        'platform': latest_app.platform,
        'platform_display': latest_app.download_target_display,
        'linux_distribution': latest_app.normalized_linux_distribution,
        'current_version': current_version,
        'current_build_number': current_build_number,
        'latest_version': latest_version,
        'latest_build_number': latest_build_number,
        'update_available': update_available,
        'force_update': force_update,
        'reason': reason,
        'download_url': request.build_absolute_uri(download_path),
        'downloads_page_url': request.build_absolute_uri(downloads_page_path),
        'release_notes': latest_app.release_notes_text,
    }


def get_country_from_ip(ip_address):
    try:
        import geoip2.database
        if os.path.exists(GEOIP_PATH):
            with geoip2.database.Reader(GEOIP_PATH) as reader:
                response = reader.country(ip_address)
                if settings.DEBUG:
                    print(f"DEBUG: GeoIP {ip_address} -> {response.country.iso_code} ({response.country.name})")
                return response.country.iso_code, response.country.name
        else:
            print(f"GeoIP database not found at: {GEOIP_PATH}")
    except Exception as e:
        print(f"Error getting country from IP: {e}")

    if ip_address in ['127.0.0.1', 'localhost', '0.0.0.0']:
        return 'KE', 'Kenya'
    return 'US', 'United States'


def _is_duplicate_request(ip_address, app_id):
    cache_key = f"dl_{app_id}_{hashlib.md5(ip_address.encode()).hexdigest()}"
    if cache.get(cache_key):
        return True
    cache.set(cache_key, True, timeout=60)
    return False


def _platform_icon(platform):
    return {
        'windows': 'fab fa-windows',
        'android': 'fab fa-android',
        'linux': 'fab fa-linux',
        'macos': 'fab fa-apple',
        'ios': 'fab fa-apple',
    }.get(platform, 'fas fa-download')


def _platform_display(platform):
    return dict(DownloadableApp.PLATFORM_CHOICES).get(platform, platform.title())


def _target_display(platform, linux_distribution=''):
    if platform == 'linux' and linux_distribution:
        return DownloadableApp.linux_distribution_label(linux_distribution)
    return _platform_display(platform)


def _active_released_apps_for_target(platform, linux_distribution=''):
    return DownloadableApp.objects.filter(
        DownloadableApp.build_target_filter(platform, linux_distribution),
        is_active=True,
        release__isnull=False,
    ).select_related('release')


def _latest_app_for_platform(platform, linux_distribution=''):
    apps = [
        app for app in _active_released_apps_for_target(platform, linux_distribution)
    ]
    apps.sort(key=_release_sort_key, reverse=True)
    return apps[0] if apps else None


def _latest_linux_apps_by_distribution():
    linux_apps = {}
    for distribution, _ in DownloadableApp.LINUX_DISTRIBUTION_CHOICES:
        app = _latest_app_for_platform('linux', distribution)
        if app:
            linux_apps[distribution] = app
    return linux_apps


def _linux_distribution_options(linux_apps=None):
    linux_apps = linux_apps if linux_apps is not None else _latest_linux_apps_by_distribution()
    options = []
    for distribution, label in DownloadableApp.LINUX_DISTRIBUTION_CHOICES:
        app = linux_apps.get(distribution)
        if not app:
            continue
        options.append({
            'value': distribution,
            'label': label,
            'icon': LINUX_DISTRO_ICONS.get(distribution, 'fab fa-linux'),
            'app': app,
            'available': True,
        })
    return options


def _build_download_cards():
    cards = []
    linux_apps = _latest_linux_apps_by_distribution()

    for platform in PLATFORM_ORDER:
        if platform == 'linux':
            if not linux_apps:
                continue
            latest_linux_app = max(linux_apps.values(), key=_release_sort_key)
            cards.append({
                'platform': platform,
                'name': 'Linux',
                'icon': _platform_icon(platform),
                'app': latest_linux_app,
                'is_linux': True,
                'available_count': len(linux_apps),
            })
            continue

        app = _latest_app_for_platform(platform)
        if app:
            cards.append({
                'platform': platform,
                'name': _platform_display(platform),
                'icon': _platform_icon(platform),
                'app': app,
                'is_linux': False,
                'available_count': 1,
            })

    return cards, _linux_distribution_options(linux_apps)


def _archived_apps_for_target(platform, linux_distribution=''):
    apps = [
        app for app in _active_released_apps_for_target(platform, linux_distribution)
        .filter(
            Q(release__keep_in_archive=True) |
            Q(release__is_major_release=True)
        )
    ]
    apps.sort(key=_release_sort_key, reverse=True)

    current_app = _latest_app_for_platform(platform, linux_distribution)
    if current_app:
        apps = [app for app in apps if app.id != current_app.id]

    if len(apps) < DownloadableApp.KEEP_ARCHIVE_FALLBACK_PER_PLATFORM:
        fallback_apps = [
            app for app in _active_released_apps_for_target(platform, linux_distribution)
            .filter(
                release__keep_in_archive=False,
                release__is_major_release=False,
            )
        ]
        fallback_apps.sort(key=_release_sort_key, reverse=True)
        for app in fallback_apps:
            if current_app and app.id == current_app.id:
                continue
            if app.id in {archived_app.id for archived_app in apps}:
                continue
            apps.append(app)
            if len(apps) >= DownloadableApp.KEEP_ARCHIVE_FALLBACK_PER_PLATFORM:
                break

    return apps[:DownloadableApp.KEEP_ARCHIVE_FALLBACK_PER_PLATFORM]


def _build_archive_groups():
    groups = []

    for platform in PLATFORM_ORDER:
        if platform == 'linux':
            for distribution, _ in DownloadableApp.LINUX_DISTRIBUTION_CHOICES:
                apps = _archived_apps_for_target(platform, distribution)
                if apps:
                    groups.append({
                        'platform': platform,
                        'linux_distribution': distribution,
                        'title': f"Linux - {_target_display(platform, distribution)}",
                        'icon': LINUX_DISTRO_ICONS.get(distribution, 'fab fa-linux'),
                        'apps': apps,
                    })
            continue

        apps = _archived_apps_for_target(platform)
        if apps:
            groups.append({
                'platform': platform,
                'linux_distribution': '',
                'title': _platform_display(platform),
                'icon': _platform_icon(platform),
                'apps': apps,
            })

    return groups


def download_list(request):
    download_cards, linux_distribution_options = _build_download_cards()

    total_downloads = TotalDownloadCount.get_total()
    terms_page   = LegalPage.objects.filter(page_type='terms').first()
    privacy_page = LegalPage.objects.filter(page_type='privacy').first()

    from datetime import datetime
    context = {
        'download_cards': download_cards,
        'linux_distribution_options': linux_distribution_options,
        'platform_card_count': len(download_cards),
        'total_downloads':  total_downloads,
        'current_year':     datetime.now().year,
        'terms_page':       terms_page,
        'privacy_page':     privacy_page,
    }
    return render(request, 'beatzlock_app/download_list.html', context)


def archived_downloads(request):
    from datetime import datetime
    context = {
        'archive_groups': _build_archive_groups(),
        'current_year': datetime.now().year,
    }
    return render(request, 'beatzlock_app/archived_downloads.html', context)


# â”€â”€ Release notes JSON (for modal fetch) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

def release_notes_json(request, app_id):
    """Returns the shared release notes text for a given platform build."""
    app = get_object_or_404(DownloadableApp, id=app_id, is_active=True)
    return JsonResponse({'notes': app.release_notes_text})


def update_check(request):
    platform = (request.GET.get('platform') or '').strip().lower()
    linux_distribution = (
        request.GET.get('distribution') or
        request.GET.get('distro') or
        request.GET.get('flavor') or
        ''
    ).strip().lower()
    current_version = (request.GET.get('version') or '').strip()
    raw_build_number = (request.GET.get('build_number') or '0').strip()

    valid_platforms = {choice[0] for choice in DownloadableApp.PLATFORM_CHOICES}
    if platform not in valid_platforms:
        return JsonResponse(
            {'error': f'platform must be one of: {", ".join(sorted(valid_platforms))}'},
            status=400,
        )

    if platform == 'linux':
        linux_distribution = linux_distribution or DownloadableApp.DEFAULT_LINUX_DISTRIBUTION
        valid_distributions = set(DownloadableApp.linux_distribution_values())
        if linux_distribution not in valid_distributions:
            return JsonResponse(
                {
                    'error': (
                        'distribution must be one of: '
                        f'{", ".join(DownloadableApp.linux_distribution_values())}'
                    )
                },
                status=400,
            )
    else:
        linux_distribution = ''

    if not current_version:
        return JsonResponse({'error': 'version query parameter is required'}, status=400)

    try:
        current_build_number = _parse_build_number(raw_build_number)
        _parse_semver(current_version)
    except ValueError as exc:
        return JsonResponse({'error': str(exc)}, status=400)

    apps = [
        app for app in _active_released_apps_for_target(platform, linux_distribution)
        if app.release
    ]

    if not apps:
        return JsonResponse(
            {
                'platform': platform,
                'platform_display': _target_display(platform, linux_distribution),
                'linux_distribution': linux_distribution,
                'current_version': current_version,
                'current_build_number': current_build_number,
                'latest_version': current_version,
                'latest_build_number': current_build_number,
                'update_available': False,
                'force_update': False,
                'reason': 'No active release is currently published for this platform.',
                'download_url': '',
                'downloads_page_url': request.build_absolute_uri(
                    reverse('beatzlock_app:download_list')
                ),
                'release_notes': '',
            }
        )

    try:
        latest_app = max(apps, key=_release_sort_key)
        payload = _build_update_payload(current_version, current_build_number, latest_app, request)
    except ValueError as exc:
        return JsonResponse({'error': str(exc)}, status=400)

    return JsonResponse(payload)


# â”€â”€ Standalone legal pages â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

LEGAL_COMING_SOON_HTML = (
    '<p>This document is being written and will be published here shortly.</p>'
)


def _legal_page_or_placeholder(page_type):
    """The stored page, or an unsaved stand-in that reads "coming soon".

    A legal document nobody has written yet is not a missing URL. Both pages are
    linked from every download listing and from inside the native apps, so a 404
    there reads as a broken site rather than as work in progress. The stand-in
    carries the same attributes the template and the JSON endpoint read, and its
    last_updated stays None -- auto_now only fills on save -- so neither shows a
    date that does not exist.
    """
    page = LegalPage.objects.filter(page_type=page_type).first()
    if page is not None:
        return page, False

    title = dict(LegalPage.PAGE_CHOICES).get(page_type, 'Legal')
    placeholder = LegalPage(
        page_type=page_type,
        title=title,
        content=LEGAL_COMING_SOON_HTML,
    )
    return placeholder, True


def legal_terms(request):
    page, coming_soon = _legal_page_or_placeholder('terms')
    return render(
        request,
        'beatzlock_app/legal_page.html',
        {'page': page, 'coming_soon': coming_soon},
    )


def legal_privacy(request):
    page, coming_soon = _legal_page_or_placeholder('privacy')
    return render(
        request,
        'beatzlock_app/legal_page.html',
        {'page': page, 'coming_soon': coming_soon},
    )


# â”€â”€ File download â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

@never_cache
def download_file(request, app_id):
    app = get_object_or_404(DownloadableApp, id=app_id, is_active=True)

    if not app.file:
        raise Http404("File not associated with this download.")
    if not os.path.exists(app.file.path):
        raise Http404("File not found on server. Please contact support.")

    x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
    if x_forwarded_for:
        ip_address = x_forwarded_for.split(',')[0].strip()
    else:
        ip_address = request.META.get('REMOTE_ADDR', '0.0.0.0')

    # â”€â”€ DEBUG override â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if settings.DEBUG:
        print(f"DEBUG: Client IP: {ip_address}")
        ip_address = '41.207.81.1'
        print(f"DEBUG: Using test IP: {ip_address}")
    # â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    already_counted = _is_duplicate_request(ip_address, app_id)

    if not already_counted:
        country_code, country_name = get_country_from_ip(ip_address)
        if settings.DEBUG:
            print(f"DEBUG: Country: {country_code} - {country_name}")

        DownloadStats.record_download(
            app=app,
            country_code=country_code,
            country_name=country_name,
        )
        TotalDownloadCount.increment()
    else:
        if settings.DEBUG:
            print(f"DEBUG: Duplicate request â€” not counting")

    try:
        # Serve via nginx X-Accel-Redirect in production so large app binaries
        # don't stream through a Gunicorn worker (fast, non-blocking downloads).
        original_filename = os.path.basename(app.file.name)
        return x_accel_file_response(
            app.file, as_attachment=True, download_name=original_filename
        )
    except Http404:
        raise
    except Exception as e:
        print(f"Error serving file: {e}")
        raise Http404("Unable to serve the file at this time.")


def legal_document_json(request, page_type):
    normalized_type = (page_type or '').strip().lower()
    if normalized_type in ('terms-of-service', 'terms_of_service', 'tos'):
        normalized_type = 'terms'
    if normalized_type not in ('terms', 'privacy'):
        return JsonResponse({'error': 'Unknown legal document.'}, status=404)

    # Same stand-in as the web pages, so a client that asks before the
    # document exists is told it is coming rather than handed a 404.
    page, coming_soon = _legal_page_or_placeholder(normalized_type)
    web_name = 'legal_terms' if normalized_type == 'terms' else 'legal_privacy'
    web_url = request.build_absolute_uri(reverse('beatzlock_app:{}'.format(web_name)))
    return JsonResponse({
        'type': page.page_type,
        'title': page.title,
        'content_html': page.content,
        'last_updated': page.last_updated.isoformat() if page.last_updated else None,
        'web_url': web_url,
        'coming_soon': coming_soon,
    })


def _rating_client_ip(request):
    x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
    if x_forwarded_for:
        return x_forwarded_for.split(',')[0].strip()
    return request.META.get('REMOTE_ADDR', '0.0.0.0')


RATING_VOTER_COOKIE = 'beatzlock_rating_voter'
RATING_VOTER_COOKIE_MAX_AGE = 60 * 60 * 24 * 365


def _rating_voter_token(request):
    cookie_value = str(request.COOKIES.get(RATING_VOTER_COOKIE) or '').strip()
    if cookie_value:
        return cookie_value

    raw = '|'.join([
        _rating_client_ip(request),
        request.META.get('HTTP_USER_AGENT', '')[:240],
        request.META.get('HTTP_ACCEPT_LANGUAGE', '')[:120],
    ])
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()


def _rating_voter_key(request):
    return _normalize_reviewer_key(_rating_voter_token(request))


def _ensure_rating_voter_cookie(request, response):
    if request.COOKIES.get(RATING_VOTER_COOKIE):
        return response

    response.set_cookie(
        RATING_VOTER_COOKIE,
        _rating_voter_token(request),
        max_age=RATING_VOTER_COOKIE_MAX_AGE,
        httponly=True,
        samesite='Lax',
    )
    return response


def _normalize_reviewer_key(value):
    raw = str(value or '').strip().lower()
    if not raw:
        return ''
    if re.fullmatch(r'[0-9a-f]{64}', raw):
        return raw
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()


def _rating_platform_entry(rating, platform):
    return rating.get_platform_review(platform) if rating else None


def _entry_int(entry, key, default=0):
    try:
        return int((entry or {}).get(key) or default)
    except (TypeError, ValueError):
        return default


def _entry_datetime_value(value):
    if isinstance(value, str):
        return parse_datetime(value)
    return value


def _rating_payload(rating, platform=''):
    if not rating:
        return None

    platform = AppRating.normalize_platform(platform or rating.platform)
    entry = _rating_platform_entry(rating, platform)
    if not entry:
        return None

    return {
        'id': rating.id,
        'platform': platform,
        'platforms': rating.platform_values,
        'platform_display': AppRating.platform_label_for(platform),
        'display_name': rating.display_name,
        'display_name_or_anonymous': rating.display_name_or_anonymous,
        'stars': _entry_int(entry, 'stars', rating.stars),
        'comment': str(entry.get('comment') or ''),
        'suggestion': str(entry.get('suggestion') or ''),
        'app_version': str(entry.get('app_version') or ''),
        'build_number': str(entry.get('build_number') or ''),
        'device_label': str(entry.get('device_label') or ''),
        'useful_count': _entry_int(entry, 'useful_count'),
        'admin_reply': str(entry.get('admin_reply') or ''),
        'admin_replied_at': entry.get('admin_replied_at') or None,
        'created_at': entry.get('created_at') or (rating.created_at.isoformat() if rating.created_at else None),
        'updated_at': entry.get('updated_at') or (rating.updated_at.isoformat() if rating.updated_at else None),
    }


def _rating_summary(queryset, platform=''):
    total = 0
    count = 0

    for rating in queryset:
        if platform:
            entry = _rating_platform_entry(rating, platform)
            if not entry:
                continue
            total += _entry_int(entry, 'stars')
            count += 1
            continue

        for value in rating.platform_values:
            entry = _rating_platform_entry(rating, value)
            if not entry:
                continue
            total += _entry_int(entry, 'stars')
            count += 1

    average = (total / count) if count else 0
    return {
        'average': round(float(average), 1),
        'count': count,
    }


def _group_ratings_for_display(ratings, selected_platform=''):
    grouped = []
    selected_platform = AppRating.normalize_platform(selected_platform) if selected_platform else ''

    for index, rating in enumerate(ratings, start=1):
        if selected_platform and not rating.get_platform_review(selected_platform):
            continue

        entry_platforms = []
        for platform in rating.platform_values:
            payload = _rating_payload(rating, platform)
            if payload:
                entry_platforms.append(payload)

        if not entry_platforms:
            continue

        entry_platforms.sort(key=lambda item: item.get('updated_at') or item.get('created_at') or '', reverse=True)
        active_platform = selected_platform if any(
            item['platform'] == selected_platform for item in entry_platforms
        ) else entry_platforms[0]['platform']
        active_entry = next(
            (item for item in entry_platforms if item['platform'] == active_platform),
            entry_platforms[0],
        )
        grouped.append({
            'group_id': f'review-group-{index}',
            'rating_id': rating.id,
            'display_name': rating.display_name_or_anonymous,
            'entries': entry_platforms,
            'active_platform': active_platform,
            'active_entry': active_entry,
        })

    return grouped


def _groups_for_template(groups):
    prepared = []
    for group in groups:
        entries = []
        for entry in group['entries']:
            item = dict(entry)
            item['created_at_dt'] = _entry_datetime_value(item.get('created_at'))
            item['updated_at_dt'] = _entry_datetime_value(item.get('updated_at'))
            item['admin_replied_at_dt'] = _entry_datetime_value(item.get('admin_replied_at'))
            entries.append(item)
        prepared.append({
            **group,
            'entries': entries,
        })
    return prepared


def _delete_rating_platform(rating, platform):
    platform = AppRating.normalize_platform(platform)
    if not rating.get_platform_review(platform):
        return False, False

    AppRatingUsefulVote.objects.filter(rating=rating, platform=platform).delete()
    rating.remove_platform_review(platform)

    if rating.platform_reviews:
        rating.sync_summary_fields()
        rating.save(update_fields=[
            'platform',
            'platform_history',
            'platform_reviews',
            'stars',
            'comment',
            'suggestion',
            'app_version',
            'build_number',
            'device_label',
            'admin_reply',
            'admin_replied_at',
            'admin_reply_sent_at',
            'useful_count',
            'updated_at',
        ])
        return True, False

    rating.delete()
    return True, True


def _ordered_rating_groups(queryset, selected_platform='', sort='newest'):
    ratings = list(queryset)
    groups = _group_ratings_for_display(ratings, selected_platform)

    if sort == 'highest':
        groups.sort(
            key=lambda item: (
                item['active_entry']['stars'],
                item['active_entry'].get('updated_at') or item['active_entry'].get('created_at') or '',
            ),
            reverse=True,
        )
    elif sort == 'lowest':
        groups.sort(
            key=lambda item: (
                item['active_entry']['stars'],
                -len(item['entries']),
                item['active_entry'].get('updated_at') or item['active_entry'].get('created_at') or '',
            ),
        )
    elif sort == 'useful':
        groups.sort(
            key=lambda item: (
                item['active_entry']['useful_count'],
                item['active_entry'].get('updated_at') or item['active_entry'].get('created_at') or '',
            ),
            reverse=True,
        )
    else:
        groups.sort(
            key=lambda item: item['active_entry'].get('updated_at') or item['active_entry'].get('created_at') or '',
            reverse=True,
        )

    return groups[:100]


@csrf_exempt
@require_POST
def submit_rating(request):
    if request.content_type and 'application/json' in request.content_type:
        try:
            data = json.loads(request.body.decode('utf-8') or '{}')
        except ValueError:
            return JsonResponse({'error': 'Invalid JSON.'}, status=400)
    else:
        data = request.POST

    reviewer_key = _normalize_reviewer_key(data.get('reviewer_key')) or _rating_voter_key(request)

    platform = str(data.get('platform') or 'unknown').strip().lower()
    platform = AppRating.normalize_platform(platform)

    try:
        stars = int(data.get('stars'))
    except (TypeError, ValueError):
        return JsonResponse({'error': 'stars must be a number from 1 to 5.'}, status=400)

    if stars < 1 or stars > 5:
        return JsonResponse({'error': 'stars must be from 1 to 5.'}, status=400)

    comment = str(data.get('comment') or '').strip()[:5000]
    suggestion = str(data.get('suggestion') or '').strip()[:5000]
    if not comment and not suggestion:
        return JsonResponse({'error': 'comment or suggestion is required.'}, status=400)

    rating = AppRating.objects.filter(reviewer_key=reviewer_key).first()
    created = rating is None
    if rating is None:
        rating = AppRating(reviewer_key=reviewer_key, platform=platform)

    rating.display_name = str(data.get('display_name') or '').strip()[:80]
    rating.account_user_id = str(data.get('account_user_id') or '').strip()[:40]
    rating.account_email = str(data.get('account_email') or '').strip()[:254]
    rating.account_username = str(data.get('account_username') or '').strip()[:150]
    now_iso = timezone.now().isoformat()
    existing_entry = rating.get_platform_review(platform) or {}
    rating.set_platform_review(platform, {
        'platform': platform,
        'stars': stars,
        'comment': comment,
        'suggestion': suggestion,
        'app_version': str(data.get('app_version') or '').strip()[:40],
        'build_number': str(data.get('build_number') or '').strip()[:40],
        'device_label': str(data.get('device_label') or '').strip()[:160],
        'created_at': existing_entry.get('created_at') or now_iso,
        'updated_at': now_iso,
        'admin_reply': str(existing_entry.get('admin_reply') or ''),
        'admin_replied_at': existing_entry.get('admin_replied_at') or None,
        'admin_reply_sent_at': existing_entry.get('admin_reply_sent_at') or None,
        'useful_count': _entry_int(existing_entry, 'useful_count'),
    })
    rating.sync_summary_fields(platform)
    rating.save()

    response = JsonResponse(
        {
            'ok': True,
            'created': created,
            'platform_created': not bool(existing_entry),
            'rating': _rating_payload(rating, platform),
            'summary': _rating_summary(
                AppRating.objects.filter(is_approved=True),
                platform=platform,
            ),
        },
        status=201 if created else 200,
    )
    return _ensure_rating_voter_cookie(request, response)


@require_GET
def my_rating(request):
    reviewer_key = _normalize_reviewer_key(request.GET.get('reviewer_key'))
    if not reviewer_key:
        return JsonResponse({'error': 'reviewer_key is required.'}, status=400)

    platform = str(request.GET.get('platform') or '').strip().lower()
    platform = AppRating.normalize_platform(platform) if platform else ''
    rating = AppRating.objects.filter(reviewer_key=reviewer_key).first()
    summary_queryset = AppRating.objects.filter(is_approved=True)
    rating_payload = _rating_payload(rating, platform) if (rating and platform) else None
    if rating_payload is None and rating and not platform:
        rating_payload = _rating_payload(rating, rating.platform)

    return JsonResponse({
        'ok': True,
        'rating': rating_payload,
        'display_name': rating.display_name if rating else '',
        'summary': _rating_summary(summary_queryset, platform=platform),
    })


@require_GET
def ratings_json(request):
    platform = str(request.GET.get('platform') or '').strip().lower()
    sort = str(request.GET.get('sort') or 'newest').strip().lower()
    platform = AppRating.normalize_platform(platform) if platform else ''

    queryset = AppRating.objects.filter(is_approved=True)
    groups = _ordered_rating_groups(queryset, platform, sort)
    platform_summaries = []
    for value, label in AppRating.PLATFORM_CHOICES:
        summary = _rating_summary(queryset, platform=value)
        platform_summaries.append({
            'platform': value,
            'label': label,
            'average': summary['average'],
            'count': summary['count'],
        })

    return JsonResponse({
        'summary': _rating_summary(queryset, platform=platform),
        'platforms': platform_summaries,
        'ratings': [group['active_entry'] for group in groups],
        'groups': groups,
    })


def rate_app(request):
    platform = str(request.GET.get('platform') or '').strip().lower()
    sort = str(request.GET.get('sort') or 'newest').strip().lower()
    if platform:
        platform = AppRating.normalize_platform(platform)

    sort_options = [
        ('newest', 'Newest'),
        ('highest', 'Highest rated'),
        ('lowest', 'Lowest rated'),
        ('useful', 'Most useful'),
    ]
    if sort not in {value for value, _ in sort_options}:
        sort = 'newest'

    base_queryset = AppRating.objects.filter(is_approved=True)
    rating_groups = _ordered_rating_groups(base_queryset, platform, sort)

    platform_summaries = []
    for value, label in AppRating.PLATFORM_CHOICES:
        summary = _rating_summary(base_queryset, platform=value)
        platform_summaries.append({
            'value': value,
            'label': label,
            'average': summary['average'],
            'count': summary['count'],
        })

    context = {
        'rating_groups': _groups_for_template(rating_groups),
        'summary': _rating_summary(base_queryset, platform=platform),
        'overall_summary': _rating_summary(base_queryset),
        'platform_choices': AppRating.PLATFORM_CHOICES,
        'platform_summaries': platform_summaries,
        'selected_platform': platform,
        'sort': sort,
        'sort_options': sort_options,
        'current_path': request.get_full_path(),
    }
    response = render(request, 'beatzlock_app/rate_app.html', context)
    return _ensure_rating_voter_cookie(request, response)


@csrf_exempt
@require_POST
def delete_rating(request):
    if request.content_type and 'application/json' in request.content_type:
        try:
            data = json.loads(request.body.decode('utf-8') or '{}')
        except ValueError:
            return JsonResponse({'error': 'Invalid JSON.'}, status=400)
    else:
        data = request.POST

    reviewer_key = _normalize_reviewer_key(data.get('reviewer_key'))
    if not reviewer_key:
        return JsonResponse({'error': 'reviewer_key is required.'}, status=400)

    raw_platform = str(data.get('platform') or '').strip().lower()
    if not raw_platform:
        return JsonResponse({'error': 'platform is required.'}, status=400)
    platform = AppRating.normalize_platform(raw_platform)

    rating = AppRating.objects.filter(reviewer_key=reviewer_key).first()
    if not rating:
        return JsonResponse({'ok': True, 'deleted': False, 'platform_deleted': False})

    deleted, record_deleted = _delete_rating_platform(rating, platform)
    response = JsonResponse({
        'ok': True,
        'deleted': deleted,
        'platform_deleted': deleted,
        'record_deleted': record_deleted,
        'summary': _rating_summary(AppRating.objects.filter(is_approved=True), platform=platform),
    })
    return _ensure_rating_voter_cookie(request, response)


@require_POST
def mark_rating_useful(request, rating_id):
    rating = get_object_or_404(AppRating, id=rating_id, is_approved=True)
    platform = str(request.POST.get('platform') or request.GET.get('platform') or '').strip().lower()
    platform = AppRating.normalize_platform(platform) if platform else ''
    if not platform or not rating.get_platform_review(platform):
        return JsonResponse({'error': 'platform is required for this review.'}, status=400)

    _, created = AppRatingUsefulVote.objects.get_or_create(
        rating=rating,
        platform=platform,
        voter_key=_rating_voter_key(request),
    )
    if created:
        reviews = dict(rating.platform_reviews or {})
        entry = dict(reviews.get(platform) or {})
        entry['useful_count'] = _entry_int(entry, 'useful_count') + 1
        reviews[platform] = entry
        rating.platform_reviews = reviews
        rating.sync_summary_fields(platform)
        rating.save(update_fields=['platform_reviews', 'platform', 'platform_history', 'stars', 'comment', 'suggestion', 'app_version', 'build_number', 'device_label', 'admin_reply', 'admin_replied_at', 'admin_reply_sent_at', 'useful_count', 'updated_at'])

    wants_json = 'application/json' in request.META.get('HTTP_ACCEPT', '')
    if wants_json:
        response = JsonResponse({
            'ok': True,
            'created': created,
            'useful_count': _entry_int(rating.get_platform_review(platform), 'useful_count'),
        })
        return _ensure_rating_voter_cookie(request, response)

    fallback = reverse('beatzlock_app:rate_app')
    response = redirect(request.POST.get('next') or request.META.get('HTTP_REFERER') or fallback)
    return _ensure_rating_voter_cookie(request, response)


# ── Account ────────────────────────────────────────────────────────────────

@login_required
def account(request):
    """The name shown on reviews, the profile image, and the password.

    Someone who arrived through Google has no usable password, so Google is
    their only way in. SetPasswordForm gives them one without asking for a
    password they have never had; anyone who already has one gets
    PasswordChangeForm, which asks for the old one first.

    The page posts from two separate forms -- the details and the password --
    so each is bound only when its own button was pressed. Nesting them in one
    form would submit a half-empty password form on every avatar upload.
    """
    profile = profile_for(request.user)
    has_password = request.user.has_usable_password()
    password_form_class = PasswordChangeForm if has_password else SetPasswordForm

    account_form = AccountForm(instance=request.user)
    avatar_form = AvatarForm(instance=profile)
    password_form = password_form_class(request.user)

    if request.method == 'POST':
        if 'remove_avatar' in request.POST:
            if profile.avatar:
                profile.avatar.delete(save=False)
                profile.avatar = None
                profile.save()
                messages.success(request, "Profile image removed.")
            return redirect('beatzlock_app:account')

        if 'set_password' in request.POST:
            password_form = password_form_class(request.user, request.POST)
            if password_form.is_valid():
                user = password_form.save()
                # Changing the password rotates the session hash, which would
                # otherwise sign them out on the very next request.
                update_session_auth_hash(request, user)
                messages.success(
                    request,
                    "Password updated." if has_password else
                    "Password set. You can now sign in with your email address too.",
                )
                return redirect('beatzlock_app:account')
        else:
            account_form = AccountForm(request.POST, instance=request.user)
            avatar_form = AvatarForm(request.POST, request.FILES, instance=profile)
            if account_form.is_valid() and avatar_form.is_valid():
                account_form.save()
                avatar_form.save()
                messages.success(request, "Account updated.")
                return redirect('beatzlock_app:account')

    return render(request, 'beatzlock_app/account.html', {
        'profile': profile,
        'account_form': account_form,
        'avatar_form': avatar_form,
        'password_form': password_form,
        'google_enabled': google_enabled(),
        'has_password': has_password,
    })


def _safe_redirect_target(candidate, fallback_name='beatzlock_app:account'):
    """Only ever send someone back into this site."""
    if candidate and candidate.startswith('/') and not candidate.startswith('//'):
        return candidate
    return reverse(fallback_name)


def signup(request):
    """Create an account and sign straight in. No confirmation step."""
    if request.user.is_authenticated:
        return redirect('beatzlock_app:account')

    next_url = request.POST.get('next') or request.GET.get('next') or ''

    if request.method == 'POST':
        form = SignUpForm(request.POST)
        if form.is_valid():
            user = form.save()
            # Nothing authenticated them, so login() has to be told which
            # backend to record on the session.
            auth_login(request, user, backend='django.contrib.auth.backends.ModelBackend')
            messages.success(request, "Welcome to {}.".format(settings.SITE_NAME))
            return redirect(_safe_redirect_target(next_url))
    else:
        form = SignUpForm()

    return render(request, 'registration/signup.html', {
        'form': form,
        'next': next_url,
    })
