
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0004_encrypteddata_deleted_accounts'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.RemoveField(
            model_name='synclog',
            name='id',
        ),
        migrations.AddField(
            model_name='synclog',
            name='last_sync_count',
            field=models.IntegerField(default=0),
        ),
        migrations.AddField(
            model_name='synclog',
            name='total_syncs',
            field=models.IntegerField(default=0),
        ),
        migrations.AlterField(
            model_name='synclog',
            name='device_id',
            field=models.CharField(blank=True, default='', max_length=255),
        ),
        migrations.AlterField(
            model_name='synclog',
            name='status',
            field=models.CharField(blank=True, default='', max_length=50),
        ),
        migrations.AlterField(
            model_name='synclog',
            name='sync_type',
            field=models.CharField(blank=True, default='', max_length=50),
        ),
        migrations.AlterField(
            model_name='synclog',
            name='timestamp',
            field=models.DateTimeField(auto_now=True),
        ),
        migrations.AlterField(
            model_name='synclog',
            name='user',
            field=models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, primary_key=True, related_name='sync_log', serialize=False, to=settings.AUTH_USER_MODEL),
        ),
    ]
