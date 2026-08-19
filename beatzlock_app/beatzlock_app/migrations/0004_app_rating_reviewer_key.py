# Generated manually for one-review-per-user app ratings.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0003_app_ratings'),
    ]

    operations = [
        migrations.AddField(
            model_name='apprating',
            name='reviewer_key',
            field=models.CharField(blank=True, db_index=True, help_text='Hashed app-user key used to keep one rating per user.', max_length=64, null=True, unique=True),
        ),
    ]
