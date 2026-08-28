# Generated for the LegalPage draft/publish/archive rework.
from django.db import migrations, models


def mark_existing_pages_published(apps, schema_editor):
    """Rows that existed before this migration were live by definition.

    is_published defaults to False, so without this every legal page would
    silently vanish from the site the moment the migration ran.
    """
    LegalPage = apps.get_model('beatzlock_app', 'LegalPage')
    for page in LegalPage.objects.all():
        LegalPage.objects.filter(pk=page.pk).update(
            is_published=True,
            published_at=page.last_updated,
            created_at=page.last_updated,
        )


def unmark_pages(apps, schema_editor):
    # Reversing only needs to leave the rows intact; the columns go away.
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0013_userprofile'),
    ]

    operations = [
        migrations.AlterModelOptions(
            name='legalpage',
            options={
                'ordering': ['-published_at', '-created_at', '-id'],
                'verbose_name': 'Legal Page',
                'verbose_name_plural': 'Legal Pages',
            },
        ),
        migrations.AlterField(
            model_name='legalpage',
            name='page_type',
            field=models.CharField(
                choices=[('terms', 'Terms of Service'), ('privacy', 'Privacy Policy')],
                db_index=True,
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name='legalpage',
            name='app_version',
            field=models.CharField(
                blank=True,
                default='',
                help_text=(
                    'The release this revision ships with, picked from App Releases. '
                    'Internal only -- it is never shown to users, on the site or in the app.'
                ),
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name='legalpage',
            name='is_published',
            field=models.BooleanField(
                db_index=True,
                default=False,
                help_text=(
                    'Off until you are ready. A draft is invisible to users and to the app -- '
                    'the previously published revision stays live. Tick this to publish; the '
                    'revision that was live moves to the archive.'
                ),
            ),
        ),
        migrations.AddField(
            model_name='legalpage',
            name='published_at',
            field=models.DateTimeField(
                blank=True,
                help_text='Set automatically the first time this revision is published.',
                null=True,
            ),
        ),
        migrations.AddField(
            model_name='legalpage',
            name='change_summary',
            field=models.CharField(
                blank=True,
                default='',
                help_text='Optional one-line note about what changed, shown on the archive list.',
                max_length=300,
            ),
        ),
        migrations.AddField(
            model_name='legalpage',
            name='created_at',
            field=models.DateTimeField(auto_now_add=True, null=True),
        ),
        migrations.AddIndex(
            model_name='legalpage',
            index=models.Index(
                fields=['page_type', 'is_published', '-published_at'],
                name='beatzlock_a_page_ty_16a307_idx',
            ),
        ),
        migrations.RunPython(mark_existing_pages_published, unmark_pages),
    ]
