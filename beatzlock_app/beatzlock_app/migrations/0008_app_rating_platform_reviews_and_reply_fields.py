from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


def split_platform_history_into_rows(apps, schema_editor):
    AppRating = apps.get_model('beatzlock_app', 'AppRating')
    db_alias = schema_editor.connection.alias
    valid_platforms = {'windows', 'android', 'linux', 'macos', 'ios', 'unknown'}

    for rating in AppRating.objects.using(db_alias).all().order_by('id'):
        reviewer_key = (rating.reviewer_key or '').strip() or f'legacy-rating-{rating.pk}'
        history = [value for value in (rating.platform_history or '').strip('|').split('|') if value]
        if not history:
            history = [rating.platform or 'unknown']

        ordered = []
        for value in history:
            normalized = value if value in valid_platforms else 'unknown'
            if normalized not in ordered:
                ordered.append(normalized)
        if not ordered:
            ordered = ['unknown']

        primary_platform = ordered[0]
        rating.reviewer_key = reviewer_key
        rating.platform = primary_platform
        rating.platform_history = f'|{primary_platform}|'
        rating.save(update_fields=['reviewer_key', 'platform', 'platform_history'])

        for platform in ordered[1:]:
            exists = AppRating.objects.using(db_alias).filter(
                reviewer_key=reviewer_key,
                platform=platform,
            ).exists()
            if exists:
                continue

            clone = AppRating.objects.using(db_alias).create(
                platform=platform,
                reviewer_key=reviewer_key,
                platform_history=f'|{platform}|',
                display_name=rating.display_name,
                stars=rating.stars,
                comment=rating.comment,
                suggestion=rating.suggestion,
                app_version=rating.app_version,
                build_number=rating.build_number,
                device_label=rating.device_label,
                useful_count=rating.useful_count,
                is_approved=rating.is_approved,
            )
            AppRating.objects.using(db_alias).filter(pk=clone.pk).update(
                created_at=rating.created_at,
                updated_at=rating.updated_at,
            )


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('beatzlock_app', '0007_app_rating_platform_history_display_name'),
    ]

    operations = [
        migrations.AlterField(
            model_name='apprating',
            name='reviewer_key',
            field=models.CharField(
                blank=True,
                db_index=True,
                help_text='Hashed app-user key used to keep one rating per user per platform.',
                max_length=64,
                null=True,
            ),
        ),
        migrations.AddField(
            model_name='apprating',
            name='account_email',
            field=models.EmailField(blank=True, default='', max_length=254),
        ),
        migrations.AddField(
            model_name='apprating',
            name='account_user_id',
            field=models.CharField(blank=True, default='', max_length=40),
        ),
        migrations.AddField(
            model_name='apprating',
            name='account_username',
            field=models.CharField(blank=True, default='', max_length=150),
        ),
        migrations.AddField(
            model_name='apprating',
            name='admin_replied_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='apprating',
            name='admin_reply',
            field=models.TextField(blank=True, default=''),
        ),
        migrations.AddField(
            model_name='apprating',
            name='admin_reply_by',
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name='beatzlock_review_replies',
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AddField(
            model_name='apprating',
            name='admin_reply_sent_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.RunPython(split_platform_history_into_rows, migrations.RunPython.noop),
        migrations.AddConstraint(
            model_name='apprating',
            constraint=models.UniqueConstraint(
                fields=('reviewer_key', 'platform'),
                name='unique_app_rating_per_user_platform',
            ),
        ),
    ]
