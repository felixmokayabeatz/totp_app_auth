# beatzlock_app/admin_download_stats.py

from django.db.models import Sum
from django.template.defaulttags import register
from django.shortcuts import render
from .models import DownloadableApp, DownloadStats, TotalDownloadCount, release_sort_key_from_app
from datetime import datetime


PLATFORM_CHART_STYLES = {
    'windows': {
        'color': '#38bdf8',
        'border_color': '#7dd3fc',
    },
    'android': {
        'color': '#22c55e',
        'border_color': '#86efac',
    },
    'linux': {
        'color': '#f59e0b',
        'border_color': '#fcd34d',
    },
    'macos': {
        'color': '#a78bfa',
        'border_color': '#c4b5fd',
    },
    'ios': {
        'color': '#fb7185',
        'border_color': '#fda4af',
    },
}

# Add this helper filter for dictionary access in templates
@register.filter
def get_item(dictionary, key):
    return dictionary.get(key)


def get_platform_chart_style(platform):
    base_platform = str(platform or '').split('-', 1)[0]
    return PLATFORM_CHART_STYLES.get(
        base_platform,
        {
            'color': '#06b6d4',
            'border_color': '#67e8f9',
        }
    )


def _country_stats_for_app_ids(app_ids):
    country_stats = []
    if not app_ids:
        return country_stats

    stats = (
        DownloadStats.objects.filter(app_id__in=app_ids)
        .values('country_code', 'country_name')
        .annotate(download_count=Sum('download_count'))
        .order_by('-download_count', 'country_name')
    )

    for stat in stats:
        country_stats.append({
            'country_code': stat['country_code'],
            'country_name': stat['country_name'],
            'download_count': stat['download_count'] or 0,
            'total': stat['download_count'] or 0,
            'flag_url': get_flag_url(stat['country_code']),
        })

    return country_stats


def _stats_total_for_app_ids(app_ids):
    if not app_ids:
        return 0
    return DownloadStats.objects.filter(app_id__in=app_ids).aggregate(
        total=Sum('download_count')
    )['total'] or 0


def _build_platform_stats(apps, platform, platform_display, is_archive=False):
    app_ids = [app.id for app in apps]
    label_suffix = " archived" if is_archive else ""
    chart_platform = apps[0].platform if apps else platform

    return {
        'app': apps[0] if apps else None,
        'apps': apps,
        'platform': platform,
        'platform_display': platform_display,
        'label': f"{platform_display}{label_suffix}",
        'total_downloads': _stats_total_for_app_ids(app_ids),
        'country_stats': _country_stats_for_app_ids(app_ids),
        'chart_style': get_platform_chart_style(chart_platform),
    }


def build_download_stats_context():
    apps_by_target = {}

    apps = list(
        DownloadableApp.objects.filter(
            is_active=True,
            release__isnull=False,
        )
        .select_related('release')
        .prefetch_related('stats')
    )

    for app in apps:
        apps_by_target.setdefault(app.build_target_key, []).append(app)

    app_stats_data = []
    archived_stats_data = []

    for target_key, target_apps in apps_by_target.items():
        target_apps.sort(key=release_sort_key_from_app, reverse=True)
        current_apps = target_apps[:DownloadableApp.KEEP_CURRENT_PER_PLATFORM]
        archived_apps = target_apps[DownloadableApp.KEEP_CURRENT_PER_PLATFORM:]
        platform_display = target_apps[0].download_target_display

        if current_apps:
            app_stats_data.append(
                _build_platform_stats(current_apps, target_key, platform_display)
            )

        if archived_apps:
            archived_stats_data.append(
                _build_platform_stats(archived_apps, target_key, platform_display, is_archive=True)
            )

    app_stats_data.sort(key=lambda item: item['platform_display'])
    archived_stats_data.sort(key=lambda item: item['platform_display'])

    current_app_ids = [
        app.id
        for app_data in app_stats_data
        for app in app_data['apps']
    ]
    archived_app_ids = [
        app.id
        for app_data in archived_stats_data
        for app in app_data['apps']
    ]

    current_downloads_all = _stats_total_for_app_ids(current_app_ids)
    archived_downloads_all = _stats_total_for_app_ids(archived_app_ids)

    top_countries = _country_stats_for_app_ids(current_app_ids)[:10]
    archived_top_countries = _country_stats_for_app_ids(archived_app_ids)[:10]

    return {
        'app_stats': app_stats_data,
        'archived_app_stats': archived_stats_data,
        'total_downloads_all': current_downloads_all,
        'archived_downloads_all': archived_downloads_all,
        'lifetime_downloads_all': TotalDownloadCount.get_total(),
        'top_countries': top_countries,
        'archived_top_countries': archived_top_countries,
        'current_year': datetime.now().year,
    }

def download_stats(request):
    """
    Display download statistics with country flags.
    Shows stats per app, per country, and total downloads.
    """
    return render(request, 'admin/download_stats.html', build_download_stats_context())


def get_flag_url(country_code):
    if not country_code or len(country_code) != 2:
        return "https://flagcdn.com/w80/un.png"  # World/unknown fallback
    return f"https://flagcdn.com/w40/{country_code.lower()}.png"
