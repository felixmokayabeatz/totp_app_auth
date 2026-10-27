
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0003_deleteotpcode_accounttombstone'),
    ]

    operations = [
        migrations.AddField(
            model_name='encrypteddata',
            name='deleted_accounts',
            field=models.TextField(blank=True, default=''),
        ),
    ]
