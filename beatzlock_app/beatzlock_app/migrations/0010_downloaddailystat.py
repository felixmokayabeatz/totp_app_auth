from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0009_merge_app_rating_records'),
    ]

    operations = [
        migrations.CreateModel(
            name='DownloadDailyStat',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('country_code', models.CharField(db_index=True, max_length=10)),
                ('country_name', models.CharField(max_length=100)),
                ('download_date', models.DateField(db_index=True)),
                ('download_count', models.PositiveIntegerField(default=0)),
                ('last_downloaded', models.DateTimeField(auto_now=True)),
                ('app', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='daily_stats', to='beatzlock_app.downloadableapp')),
            ],
            options={
                'verbose_name': 'Daily Download Statistic',
                'verbose_name_plural': 'Daily Download Statistics',
                'ordering': ['-download_date', '-download_count', 'country_name'],
                'unique_together': {('app', 'country_code', 'download_date')},
            },
        ),
    ]
