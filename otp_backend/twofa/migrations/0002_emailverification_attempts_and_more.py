
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('twofa', '0001_initial'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AddField(
            model_name='emailverification',
            name='attempts',
            field=models.PositiveSmallIntegerField(default=0),
        ),
        migrations.AddIndex(
            model_name='emailverification',
            index=models.Index(fields=['user', 'is_used', '-created_at'], name='twofa_user_unused_recent'),
        ),
    ]
