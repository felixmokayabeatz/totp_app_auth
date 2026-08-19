# Generated manually for rating platform history and public reviewer names.

from django.db import migrations, models


def seed_platform_history(apps, schema_editor):
    AppRating = apps.get_model('beatzlock_app', 'AppRating')
    for rating in AppRating.objects.all().only('id', 'platform', 'platform_history'):
        if rating.platform_history:
            continue
        platform = rating.platform or 'unknown'
        rating.platform_history = f'|{platform}|'
        rating.save(update_fields=['platform_history'])


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0006_alter_apprelease_release_notes_file'),
    ]

    operations = [
        migrations.AddField(
            model_name='apprating',
            name='display_name',
            field=models.CharField(blank=True, default='', max_length=80),
        ),
        migrations.AddField(
            model_name='apprating',
            name='platform_history',
            field=models.CharField(
                blank=True,
                default='',
                help_text='Ordered platform slugs this user has submitted or edited from.',
                max_length=240,
            ),
        ),
        migrations.RunPython(seed_platform_history, migrations.RunPython.noop),
    ]
