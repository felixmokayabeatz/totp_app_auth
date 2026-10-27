from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('beatzlock_app', '0014_legalpage_revisions'),
    ]

    operations = [
        migrations.RemoveField(
            model_name='legalpage',
            name='change_summary',
        ),
    ]
