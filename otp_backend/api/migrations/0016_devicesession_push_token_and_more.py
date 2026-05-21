from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0015_passwordlessloginrequest_sync_unlock_payload_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='devicesession',
            name='push_platform',
            field=models.CharField(blank=True, default='', max_length=30),
        ),
        migrations.AddField(
            model_name='devicesession',
            name='push_token',
            field=models.TextField(blank=True, default=''),
        ),
        migrations.AddField(
            model_name='devicesession',
            name='push_token_updated_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
