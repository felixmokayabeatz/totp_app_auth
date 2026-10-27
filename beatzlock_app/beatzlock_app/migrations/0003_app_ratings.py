
from django.db import migrations, models
import django.core.validators
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0002_consolidate_country_downloads'),
    ]

    operations = [
        migrations.CreateModel(
            name='AppRating',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('platform', models.CharField(choices=[('windows', 'Windows (EXE)'), ('android', 'Android (APK)'), ('linux', 'Linux'), ('macos', 'macOS'), ('ios', 'iOS'), ('unknown', 'Unknown')], db_index=True, default='unknown', max_length=20)),
                ('stars', models.PositiveSmallIntegerField(validators=[django.core.validators.MinValueValidator(1), django.core.validators.MaxValueValidator(5)])),
                ('comment', models.TextField(blank=True, default='')),
                ('suggestion', models.TextField(blank=True, default='')),
                ('app_version', models.CharField(blank=True, default='', max_length=40)),
                ('build_number', models.CharField(blank=True, default='', max_length=40)),
                ('device_label', models.CharField(blank=True, default='', max_length=160)),
                ('useful_count', models.PositiveIntegerField(default=0)),
                ('is_approved', models.BooleanField(default=True, help_text='Uncheck to hide this review from the public ratings page.')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'verbose_name': 'App Rating',
                'verbose_name_plural': 'App Ratings',
                'ordering': ['-created_at'],
            },
        ),
        migrations.CreateModel(
            name='AppRatingUsefulVote',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('voter_key', models.CharField(db_index=True, max_length=64)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('rating', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='useful_votes', to='beatzlock_app.apprating')),
            ],
            options={
                'verbose_name': 'Rating Useful Vote',
                'verbose_name_plural': 'Rating Useful Votes',
                'unique_together': {('rating', 'voter_key')},
            },
        ),
    ]

