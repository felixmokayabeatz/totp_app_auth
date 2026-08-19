import hashlib

from django.db import migrations, models


VALID_PLATFORMS = {'windows', 'android', 'linux', 'macos', 'ios', 'unknown'}


def _normalize_platform(value):
    return value if value in VALID_PLATFORMS else 'unknown'


def _history_values(rating):
    values = [value for value in (rating.platform_history or '').strip('|').split('|') if value]
    values.append(rating.platform or 'unknown')
    ordered = []
    for value in values:
        normalized = _normalize_platform(value)
        if normalized not in ordered:
            ordered.append(normalized)
    return ordered or ['unknown']


def _entry_payload(rating, platform):
    return {
        'platform': platform,
        'stars': int(rating.stars or 1),
        'comment': str(rating.comment or ''),
        'suggestion': str(rating.suggestion or ''),
        'app_version': str(rating.app_version or ''),
        'build_number': str(rating.build_number or ''),
        'device_label': str(rating.device_label or ''),
        'created_at': rating.created_at.isoformat() if rating.created_at else None,
        'updated_at': rating.updated_at.isoformat() if rating.updated_at else None,
        'admin_reply': str(rating.admin_reply or ''),
        'admin_replied_at': rating.admin_replied_at.isoformat() if rating.admin_replied_at else None,
        'admin_reply_sent_at': rating.admin_reply_sent_at.isoformat() if rating.admin_reply_sent_at else None,
        'useful_count': int(rating.useful_count or 0),
    }


def _entry_sort_value(entry):
    return entry.get('updated_at') or entry.get('created_at') or ''


def _merge_app_rating_records(apps, schema_editor):
    AppRating = apps.get_model('beatzlock_app', 'AppRating')
    AppRatingUsefulVote = apps.get_model('beatzlock_app', 'AppRatingUsefulVote')
    db_alias = schema_editor.connection.alias

    ratings = list(AppRating.objects.using(db_alias).all().order_by('id'))
    grouped = {}

    for rating in ratings:
        reviewer_key = (rating.reviewer_key or '').strip()
        if not reviewer_key:
            reviewer_key = hashlib.sha256(f'legacy-rating-{rating.pk}'.encode('utf-8')).hexdigest()
            rating.reviewer_key = reviewer_key
            rating.save(update_fields=['reviewer_key'])
        grouped.setdefault(reviewer_key, []).append(rating)

    for reviewer_key, items in grouped.items():
        primary = items[0]
        ordered_platforms = []
        platform_reviews = {}
        display_name = ''
        account_user_id = ''
        account_email = ''
        account_username = ''
        selected_source = primary
        selected_platform = _normalize_platform(primary.platform or 'unknown')

        for item in items:
            for value in _history_values(item):
                if value not in ordered_platforms:
                    ordered_platforms.append(value)

            item_platform = _normalize_platform(item.platform or 'unknown')
            entry = _entry_payload(item, item_platform)
            existing = platform_reviews.get(item_platform)
            if not existing or _entry_sort_value(entry) >= _entry_sort_value(existing):
                platform_reviews[item_platform] = entry

            if item.display_name and (not display_name or item.updated_at >= selected_source.updated_at):
                display_name = item.display_name
            if item.account_user_id and (not account_user_id or item.updated_at >= selected_source.updated_at):
                account_user_id = item.account_user_id
            if item.account_email and (not account_email or item.updated_at >= selected_source.updated_at):
                account_email = item.account_email
            if item.account_username and (not account_username or item.updated_at >= selected_source.updated_at):
                account_username = item.account_username
            if item.updated_at >= selected_source.updated_at:
                selected_source = item
                selected_platform = item_platform

        for item in items:
            item_platform = _normalize_platform(item.platform or 'unknown')
            votes = list(AppRatingUsefulVote.objects.using(db_alias).filter(rating_id=item.pk))
            for vote in votes:
                duplicate_exists = AppRatingUsefulVote.objects.using(db_alias).filter(
                    rating_id=primary.pk,
                    platform=item_platform,
                    voter_key=vote.voter_key,
                ).exclude(pk=vote.pk).exists()
                if duplicate_exists:
                    vote.delete()
                    continue
                vote.rating_id = primary.pk
                vote.platform = item_platform
                vote.save(update_fields=['rating', 'platform'])

        total_useful = 0
        for platform in list(platform_reviews.keys()):
            vote_count = AppRatingUsefulVote.objects.using(db_alias).filter(
                rating_id=primary.pk,
                platform=platform,
            ).count()
            platform_reviews[platform]['useful_count'] = vote_count or int(platform_reviews[platform].get('useful_count') or 0)
            total_useful += int(platform_reviews[platform]['useful_count'] or 0)
            if platform not in ordered_platforms:
                ordered_platforms.append(platform)

        selected_entry = dict(platform_reviews.get(selected_platform) or {})
        primary.reviewer_key = reviewer_key
        primary.platform = selected_platform
        primary.platform_history = '|' + '|'.join(ordered_platforms or [selected_platform]) + '|'
        primary.platform_reviews = platform_reviews
        primary.display_name = display_name or primary.display_name or ''
        primary.stars = int(selected_entry.get('stars') or primary.stars or 1)
        primary.comment = str(selected_entry.get('comment') or primary.comment or '')
        primary.suggestion = str(selected_entry.get('suggestion') or primary.suggestion or '')
        primary.app_version = str(selected_entry.get('app_version') or primary.app_version or '')
        primary.build_number = str(selected_entry.get('build_number') or primary.build_number or '')
        primary.device_label = str(selected_entry.get('device_label') or primary.device_label or '')
        primary.account_user_id = account_user_id or primary.account_user_id or ''
        primary.account_email = account_email or primary.account_email or ''
        primary.account_username = account_username or primary.account_username or ''
        primary.admin_reply = str(selected_entry.get('admin_reply') or primary.admin_reply or '')
        primary.admin_replied_at = selected_source.admin_replied_at
        primary.admin_reply_sent_at = selected_source.admin_reply_sent_at
        primary.admin_reply_by_id = selected_source.admin_reply_by_id
        primary.useful_count = total_useful
        primary.save()

        for item in items[1:]:
            if item.pk != primary.pk:
                item.delete()


class Migration(migrations.Migration):
    atomic = False

    dependencies = [
        ('beatzlock_app', '0008_app_rating_platform_reviews_and_reply_fields'),
    ]

    operations = [
        migrations.AddField(
            model_name='apprating',
            name='platform_reviews',
            field=models.JSONField(blank=True, default=dict, help_text='Per-platform review payloads stored inside a single user review record.'),
        ),
        migrations.AddField(
            model_name='appratingusefulvote',
            name='platform',
            field=models.CharField(db_index=True, default='unknown', max_length=20),
        ),
        migrations.AlterUniqueTogether(
            name='appratingusefulvote',
            unique_together={('rating', 'platform', 'voter_key')},
        ),
        migrations.RemoveConstraint(
            model_name='apprating',
            name='unique_app_rating_per_user_platform',
        ),
        migrations.RunPython(_merge_app_rating_records, migrations.RunPython.noop),
        migrations.AddConstraint(
            model_name='apprating',
            constraint=models.UniqueConstraint(fields=('reviewer_key',), name='unique_app_rating_per_user'),
        ),
    ]
