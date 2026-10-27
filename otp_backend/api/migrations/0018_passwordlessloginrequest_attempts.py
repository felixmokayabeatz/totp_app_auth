
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0017_deleteotpcode_attempts'),
    ]

    operations = [
        migrations.AddField(
            model_name='passwordlessloginrequest',
            name='attempts',
            field=models.PositiveSmallIntegerField(default=0),
        ),
    ]
