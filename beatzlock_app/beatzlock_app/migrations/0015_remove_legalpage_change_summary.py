# change_summary was dropped from the LegalPage revision form. 0014 had already
# been applied when that decision was made, so the column is removed here
# rather than by editing history that has already run.
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
