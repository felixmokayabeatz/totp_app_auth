from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0011_devicesession_device_kind_passwordlessloginrequest'),
    ]

    operations = [
        migrations.AlterField(
            model_name='passwordlessloginrequest',
            name='verification_code',
            field=models.TextField(),
        ),
    ]
