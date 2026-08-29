from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion
import uuid


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('api', '0008_appnotification'),
    ]

    operations = [
        migrations.CreateModel(
            name='DeviceSession',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('device_id', models.CharField(blank=True, db_index=True, default='', max_length=255)),
                ('device_label', models.CharField(blank=True, default='Unknown device', max_length=120)),
                ('user_agent', models.TextField(blank=True, default='')),
                ('ip_address', models.CharField(blank=True, default='', max_length=128)),
                ('is_active', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('last_seen_at', models.DateTimeField(auto_now_add=True)),
                ('revoked_at', models.DateTimeField(blank=True, null=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='device_sessions', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-last_seen_at', '-created_at'],
            },
        ),
    ]
