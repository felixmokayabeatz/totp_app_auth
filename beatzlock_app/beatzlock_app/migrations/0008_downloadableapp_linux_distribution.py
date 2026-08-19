from django.db import migrations, models


LINUX_DISTRIBUTION_CHOICES = [
    ('ubuntu', 'Ubuntu / Debian (.deb)'),
    ('kali', 'Kali Linux (.deb)'),
    ('fedora', 'Fedora (.rpm)'),
    ('debian', 'Debian (.deb)'),
    ('arch', 'Arch Linux'),
    ('opensuse', 'openSUSE'),
    ('manjaro', 'Manjaro'),
]


def seed_existing_linux_builds(apps, schema_editor):
    DownloadableApp = apps.get_model('beatzlock_app', 'DownloadableApp')
    linux_builds = DownloadableApp.objects.filter(
        platform='linux',
        linux_distribution='',
    ).only('id', 'file')

    for build in linux_builds:
        filename = str(build.file or '').lower()
        build.linux_distribution = 'fedora' if filename.endswith('.rpm') else 'ubuntu'
        build.save(update_fields=['linux_distribution'])


def unseed_existing_linux_builds(apps, schema_editor):
    DownloadableApp = apps.get_model('beatzlock_app', 'DownloadableApp')
    DownloadableApp.objects.filter(
        platform='linux',
        linux_distribution='ubuntu',
    ).update(linux_distribution='')


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0007_app_rating_platform_history_display_name'),
    ]

    operations = [
        migrations.AddField(
            model_name='downloadableapp',
            name='linux_distribution',
            field=models.CharField(
                blank=True,
                choices=LINUX_DISTRIBUTION_CHOICES,
                db_index=True,
                default='',
                help_text=(
                    'Linux builds only. Existing generic Linux builds are treated as '
                    'Ubuntu / Debian unless you choose another distro.'
                ),
                max_length=30,
            ),
        ),
        migrations.RunPython(seed_existing_linux_builds, unseed_existing_linux_builds),
    ]
