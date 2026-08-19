from django.db import migrations
from django.db.models import Count, Max, Sum


def consolidate_country_downloads(apps, schema_editor):
    DownloadStats = apps.get_model('beatzlock_app', 'DownloadStats')
    IndividualDownload = apps.get_model('beatzlock_app', 'IndividualDownload')
    TotalDownloadCount = apps.get_model('beatzlock_app', 'TotalDownloadCount')

    if IndividualDownload.objects.exists():
        DownloadStats.objects.all().delete()

        aggregated = (
            IndividualDownload.objects.values('app_id', 'country_code', 'country_name')
            .annotate(download_count=Count('id'), last_downloaded=Max('downloaded_at'))
            .order_by()
        )

        total_downloads = 0
        for row in aggregated:
            DownloadStats.objects.create(
                app_id=row['app_id'],
                country_code=row['country_code'],
                country_name=row['country_name'],
                download_count=row['download_count'],
                last_downloaded=row['last_downloaded'],
            )
            total_downloads += row['download_count']
    else:
        total_downloads = (
            DownloadStats.objects.aggregate(total=Sum('download_count'))['total'] or 0
        )

    TotalDownloadCount.objects.update_or_create(
        id=1,
        defaults={'total_downloads': total_downloads},
    )


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0001_initial'),
    ]

    operations = [
        migrations.RunPython(consolidate_country_downloads, migrations.RunPython.noop),
        migrations.AlterModelOptions(
            name='downloadstats',
            options={
                'ordering': ['-download_count', '-last_downloaded', 'country_name'],
                'verbose_name_plural': 'Download Statistics',
            },
        ),
        migrations.DeleteModel(
            name='IndividualDownload',
        ),
    ]
