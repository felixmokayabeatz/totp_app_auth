from django.db import migrations, models


def set_initial_primary_sessions(apps, schema_editor):
    DeviceSession = apps.get_model('api', 'DeviceSession')

    user_ids = (
        DeviceSession.objects.filter(is_active=True, revoked_at__isnull=True)
        .values_list('user_id', flat=True)
        .distinct()
    )

    for user_id in user_ids:
        primary_exists = DeviceSession.objects.filter(
            user_id=user_id,
            is_active=True,
            revoked_at__isnull=True,
            is_primary=True,
        ).exists()
        if primary_exists:
            continue

        session = (
            DeviceSession.objects.filter(
                user_id=user_id,
                is_active=True,
                revoked_at__isnull=True,
            )
            .order_by('-last_seen_at', '-created_at')
            .first()
        )
        if session is None:
            continue

        session.is_primary = True
        session.save(update_fields=['is_primary'])


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0009_devicesession'),
    ]

    operations = [
        migrations.AddField(
            model_name='devicesession',
            name='is_primary',
            field=models.BooleanField(default=False),
        ),
        migrations.RunPython(
            set_initial_primary_sessions,
            migrations.RunPython.noop,
        ),
    ]
