# Generated for BeatzLock release archive flags.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0004_app_rating_reviewer_key'),
    ]

    operations = [
        migrations.AddField(
            model_name='apprelease',
            name='is_major_release',
            field=models.BooleanField(
                default=False,
                help_text='Mark important major releases so they can be found in the older versions page.',
            ),
        ),
        migrations.AddField(
            model_name='apprelease',
            name='keep_in_archive',
            field=models.BooleanField(
                default=False,
                help_text='Protect this release from automatic cleanup and show it on the older versions page.',
            ),
        ),
    ]
