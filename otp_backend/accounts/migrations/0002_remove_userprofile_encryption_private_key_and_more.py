
from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0001_initial'),
    ]

    operations = [
        migrations.RemoveField(
            model_name='userprofile',
            name='encryption_private_key',
        ),
        migrations.RemoveField(
            model_name='userprofile',
            name='encryption_public_key',
        ),
    ]
