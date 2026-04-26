from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0006_backupcodeset'),
    ]

    operations = [
        migrations.AddField(
            model_name='backupcodeset',
            name='last_used_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
