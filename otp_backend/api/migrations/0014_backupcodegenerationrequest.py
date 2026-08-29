from django.conf import settings
import uuid
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('api', '0013_devicesession_device_fingerprint'),
    ]

    operations = [
        migrations.CreateModel(
            name='BackupCodeGenerationRequest',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('requester_device_id', models.CharField(blank=True, default='', max_length=255)),
                ('requester_device_label', models.CharField(blank=True, default='Unknown device', max_length=120)),
                ('requester_device_kind', models.CharField(choices=[('unknown', 'Unknown'), ('mobile', 'Mobile'), ('desktop', 'Desktop'), ('web', 'Web')], default='unknown', max_length=20)),
                ('status', models.CharField(choices=[('pending', 'Pending'), ('denied', 'Denied'), ('completed', 'Completed'), ('expired', 'Expired')], default='pending', max_length=20)),
                ('expires_at', models.DateTimeField()),
                ('approved_at', models.DateTimeField(blank=True, null=True)),
                ('completed_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('reviewed_by_session', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='reviewed_backup_code_generation_requests', to='api.devicesession')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='backup_code_generation_requests', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at'],
            },
        ),
    ]
