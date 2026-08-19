import json
from datetime import datetime, timedelta

from django.contrib.admin.views.decorators import staff_member_required
from django.db.models import Sum
from django.shortcuts import render
from django.template.defaulttags import register
from django.utils import timezone

from beatzlock_app.models import (
    DownloadDailyStat,
    DownloadStats,
    DownloadableApp,
    TotalDownloadCount,
    release_sort_key_from_app,
)


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

RANGE_OPTIONS = [
    {'value': '1m', 'label': 'Last 1 month'},
    {'value': '3m', 'label': 'Last 3 months'},
    {'value': '6m', 'label': 'Last 6 months'},
    {'value': '12m', 'label': 'Last 12 months'},
    {'value': 'custom', 'label': 'Custom dates'},
]

RANGE_DAYS = {
    '1m': 30,
    '3m': 90,
    '6m': 183,
    '12m': 365,
}

COUNTRY_SORT_OPTIONS = [
    {'value': 'downloads_desc', 'label': 'Downloads high to low'},
    {'value': 'country_asc', 'label': 'Country A to Z'},
    {'value': 'country_desc', 'label': 'Country Z to A'},
]


@register.filter
def get_item(dictionary, key):
    return dictionary.get(key)


def get_platform_chart_style(platform):
    return PLATFORM_CHART_STYLES.get(
        platform,
        {
            'color': '#06b6d4',
            'border_color': '#67e8f9',
        }
    )


def get_flag_url(country_code):
    if not country_code or len(country_code) != 2:
        return "https://flagcdn.com/w80/un.png"
    return f"https://flagcdn.com/w40/{country_code.lower()}.png"


def _normalize_country_sort(value):
    valid = {item['value'] for item in COUNTRY_SORT_OPTIONS}
    return value if value in valid else 'downloads_desc'


def _country_sort_label(value):
    for option in COUNTRY_SORT_OPTIONS:
        if option['value'] == value:
            return option['label']
    return COUNTRY_SORT_OPTIONS[0]['label']


def _sort_country_rows(rows, country_sort):
    if country_sort == 'country_asc':
        return sorted(rows, key=lambda item: (item['country_name'].lower(), -item['download_count']))
    if country_sort == 'country_desc':
        return sorted(rows, key=lambda item: (item['country_name'].lower(), item['download_count']), reverse=True)
    return sorted(rows, key=lambda item: (-item['download_count'], item['country_name'].lower()))


def _country_stats_for_app_ids(app_ids, country_sort='downloads_desc'):
    if not app_ids:
        return []

    stats = (
        DownloadStats.objects.filter(app_id__in=app_ids)
        .values('country_code', 'country_name')
        .annotate(download_count=Sum('download_count'))
    )

    rows = [
        {
            'country_code': stat['country_code'],
            'country_name': stat['country_name'],
            'download_count': stat['download_count'] or 0,
            'total': stat['download_count'] or 0,
            'flag_url': get_flag_url(stat['country_code']),
        }
        for stat in stats
    ]
    return _sort_country_rows(rows, country_sort)


def _stats_total_for_app_ids(app_ids):
    if not app_ids:
        return 0
    return DownloadStats.objects.filter(app_id__in=app_ids).aggregate(
        total=Sum('download_count')
    )['total'] or 0


def _build_platform_stats(apps, platform, platform_display, country_sort='downloads_desc', is_archive=False):
    app_ids = [app.id for app in apps]
    label_suffix = " archived" if is_archive else ""

    return {
        'app': apps[0] if apps else None,
        'apps': apps,
        'platform': platform,
        'platform_display': platform_display,
        'label': f"{platform_display}{label_suffix}",
        'total_downloads': _stats_total_for_app_ids(app_ids),
        'country_stats': _country_stats_for_app_ids(app_ids, country_sort=country_sort),
        'chart_style': get_platform_chart_style(platform),
    }


def _parse_iso_date(value):
    try:
        return datetime.strptime(str(value or '').strip(), '%Y-%m-%d').date()
    except (TypeError, ValueError):
        return None


def _resolve_range_filters(request=None):
    today = timezone.localdate()
    selected_range = '1m'
    start_date = today - timedelta(days=RANGE_DAYS[selected_range] - 1)
    end_date = today
    custom_start_date = ''
    custom_end_date = ''

    if not request:
        return {
            'selected_range': selected_range,
            'start_date': start_date,
            'end_date': end_date,
            'custom_start_date': custom_start_date,
            'custom_end_date': custom_end_date,
        }

    requested_range = (request.GET.get('range') or '1m').strip().lower()
    if requested_range == 'custom':
        parsed_start = _parse_iso_date(request.GET.get('start_date'))
        parsed_end = _parse_iso_date(request.GET.get('end_date'))
        if parsed_start and parsed_end:
            if parsed_start > parsed_end:
                parsed_start, parsed_end = parsed_end, parsed_start
            start_date = parsed_start
            end_date = parsed_end
            selected_range = 'custom'
            custom_start_date = start_date.isoformat()
            custom_end_date = end_date.isoformat()
        else:
            custom_start_date = str(request.GET.get('start_date') or '').strip()
            custom_end_date = str(request.GET.get('end_date') or '').strip()
    elif requested_range in RANGE_DAYS:
        selected_range = requested_range
        start_date = today - timedelta(days=RANGE_DAYS[selected_range] - 1)
        end_date = today

    return {
        'selected_range': selected_range,
        'start_date': start_date,
        'end_date': end_date,
        'custom_start_date': custom_start_date,
        'custom_end_date': custom_end_date,
    }


def _build_daily_series(app_ids, start_date, end_date, country_code=''):
    labels = []
    points = []

    if start_date > end_date:
        start_date, end_date = end_date, start_date

    totals_by_date = {}
    if app_ids:
        query = DownloadDailyStat.objects.filter(
            app_id__in=app_ids,
            download_date__range=(start_date, end_date),
        )
        if country_code:
            query = query.filter(country_code=country_code)
        for row in query.values('download_date').annotate(total=Sum('download_count')):
            totals_by_date[row['download_date']] = row['total'] or 0

    cursor = start_date
    while cursor <= end_date:
        labels.append(cursor.isoformat())
        points.append(int(totals_by_date.get(cursor, 0)))
        cursor += timedelta(days=1)

    return {
        'labels': labels,
        'points': points,
        'total': sum(points),
    }


def _country_options_for_app_ids(app_ids):
    if not app_ids:
        return []

    countries = (
        DownloadStats.objects.filter(app_id__in=app_ids)
        .values('country_code', 'country_name')
        .annotate(download_count=Sum('download_count'))
        .order_by('country_name')
    )
    return [
        {
            'country_code': item['country_code'],
            'country_name': item['country_name'],
            'download_count': item['download_count'] or 0,
        }
        for item in countries
    ]


def build_download_stats_context(request=None):
    platform_labels = dict(DownloadableApp.PLATFORM_CHOICES)
    apps_by_platform = {}
    country_sort = _normalize_country_sort(
        (request.GET.get('country_sort') or 'downloads_desc').strip().lower()
    ) if request else 'downloads_desc'

    apps = list(
        DownloadableApp.objects.filter(
            is_active=True,
            release__isnull=False,
        )
        .select_related('release')
        .prefetch_related('stats')
    )

    for app in apps:
        apps_by_platform.setdefault(app.platform, []).append(app)

    app_stats_data = []
    archived_stats_data = []

    for platform, platform_apps in apps_by_platform.items():
        platform_apps.sort(key=release_sort_key_from_app, reverse=True)
        current_apps = platform_apps[:DownloadableApp.KEEP_CURRENT_PER_PLATFORM]
        archived_apps = platform_apps[DownloadableApp.KEEP_CURRENT_PER_PLATFORM:]
        platform_display = platform_labels.get(platform, platform.title())

        if current_apps:
            app_stats_data.append(
                _build_platform_stats(
                    current_apps,
                    platform,
                    platform_display,
                    country_sort=country_sort,
                )
            )

        if archived_apps:
            archived_stats_data.append(
                _build_platform_stats(
                    archived_apps,
                    platform,
                    platform_display,
                    country_sort=country_sort,
                    is_archive=True,
                )
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
    all_app_ids = current_app_ids + archived_app_ids

    current_downloads_all = _stats_total_for_app_ids(current_app_ids)
    archived_downloads_all = _stats_total_for_app_ids(archived_app_ids)

    top_countries = _country_stats_for_app_ids(current_app_ids, country_sort=country_sort)[:10]
    archived_top_countries = _country_stats_for_app_ids(archived_app_ids, country_sort=country_sort)[:10]

    countries_for_filter = _country_options_for_app_ids(all_app_ids)
    valid_country_codes = {item['country_code'] for item in countries_for_filter}
    selected_country_code = (request.GET.get('country') or '').strip().upper() if request else ''
    if selected_country_code not in valid_country_codes:
        selected_country_code = ''

    selected_country_name = 'All countries'
    if selected_country_code:
        for country in countries_for_filter:
            if country['country_code'] == selected_country_code:
                selected_country_name = country['country_name']
                break

    range_filters = _resolve_range_filters(request)
    current_series = _build_daily_series(
        current_app_ids,
        range_filters['start_date'],
        range_filters['end_date'],
        country_code=selected_country_code,
    )
    archived_series = _build_daily_series(
        archived_app_ids,
        range_filters['start_date'],
        range_filters['end_date'],
        country_code=selected_country_code,
    )
    earliest_daily_date = (
        DownloadDailyStat.objects.filter(app_id__in=all_app_ids)
        .order_by('download_date')
        .values_list('download_date', flat=True)
        .first()
    ) if all_app_ids else None

    return {
        'app_stats': app_stats_data,
        'archived_app_stats': archived_stats_data,
        'total_downloads_all': current_downloads_all,
        'archived_downloads_all': archived_downloads_all,
        'lifetime_downloads_all': TotalDownloadCount.get_total(),
        'top_countries': top_countries,
        'archived_top_countries': archived_top_countries,
        'current_year': timezone.now().year,
        'range_options': RANGE_OPTIONS,
        'country_sort_options': COUNTRY_SORT_OPTIONS,
        'country_options': countries_for_filter,
        'selected_range': range_filters['selected_range'],
        'selected_country_code': selected_country_code,
        'selected_country_name': selected_country_name,
        'country_sort': country_sort,
        'country_sort_label': _country_sort_label(country_sort),
        'start_date': range_filters['start_date'],
        'end_date': range_filters['end_date'],
        'custom_start_date': range_filters['custom_start_date'],
        'custom_end_date': range_filters['custom_end_date'],
        'timeline_labels': current_series['labels'],
        'timeline_current_points': current_series['points'],
        'timeline_archived_points': archived_series['points'],
        'timeline_labels_json': json.dumps(current_series['labels']),
        'timeline_current_points_json': json.dumps(current_series['points']),
        'timeline_archived_points_json': json.dumps(archived_series['points']),
        'timeline_current_total': current_series['total'],
        'timeline_archived_total': archived_series['total'],
        'timeline_total': current_series['total'] + archived_series['total'],
        'timeline_has_data': any(current_series['points']) or any(archived_series['points']),
        'earliest_daily_date': earliest_daily_date,
    }


@staff_member_required
def download_stats(request):
    return render(request, 'console/download_stats.html', build_download_stats_context(request))
