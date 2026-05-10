from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0012_bulkaccountdeleterequest'),
    ]

    operations = [
        migrations.AddField(
            model_name='devicesession',
            name='device_fingerprint',
            field=models.CharField(blank=True, db_index=True, default='', max_length=255),
        ),
    ]
