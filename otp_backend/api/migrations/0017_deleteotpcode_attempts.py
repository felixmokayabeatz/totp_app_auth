
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0016_devicesession_push_token_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='deleteotpcode',
            name='attempts',
            field=models.PositiveSmallIntegerField(default=0),
        ),
    ]
