from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion
import uuid


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('api', '0010_devicesession_is_primary'),
    ]

    operations = [
        migrations.AddField(
            model_name='devicesession',
            name='device_kind',
            field=models.CharField(
                choices=[
                    ('unknown', 'Unknown'),
                    ('mobile', 'Mobile'),
                    ('desktop', 'Desktop'),
                    ('web', 'Web'),
                ],
                default='unknown',
                max_length=20,
            ),
        ),
        migrations.CreateModel(
            name='PasswordlessLoginRequest',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('requester_device_id', models.CharField(blank=True, default='', max_length=255)),
                ('requester_device_label', models.CharField(blank=True, default='Unknown device', max_length=120)),
                ('requester_device_kind', models.CharField(choices=[('unknown', 'Unknown'), ('mobile', 'Mobile'), ('desktop', 'Desktop'), ('web', 'Web')], default='unknown', max_length=20)),
                ('verification_code', models.CharField(max_length=7)),
                ('status', models.CharField(choices=[('pending', 'Pending'), ('approved', 'Approved'), ('denied', 'Denied'), ('completed', 'Completed'), ('expired', 'Expired')], default='pending', max_length=20)),
                ('expires_at', models.DateTimeField()),
                ('approved_at', models.DateTimeField(blank=True, null=True)),
                ('completed_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('reviewed_by_session', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='reviewed_passwordless_requests', to='api.devicesession')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='passwordless_login_requests', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at'],
            },
        ),
    ]
