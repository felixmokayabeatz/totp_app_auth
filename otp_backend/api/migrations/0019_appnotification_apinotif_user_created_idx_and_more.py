
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0018_passwordlessloginrequest_attempts'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AddIndex(
            model_name='appnotification',
            index=models.Index(fields=['user', '-created_at'], name='apinotif_user_created_idx'),
        ),
        migrations.AddIndex(
            model_name='appnotification',
            index=models.Index(fields=['user', 'is_read'], name='apinotif_user_unread_idx'),
        ),
        migrations.AddIndex(
            model_name='backupcodegenerationrequest',
            index=models.Index(fields=['user', '-created_at'], name='apibkupreq_user_created_idx'),
        ),
        migrations.AddIndex(
            model_name='backupcodegenerationrequest',
            index=models.Index(fields=['status', 'expires_at'], name='apibkupreq_status_exp_idx'),
        ),
        migrations.AddIndex(
            model_name='bulkaccountdeleterequest',
            index=models.Index(fields=['user', '-created_at'], name='apibulkdel_user_created_idx'),
        ),
        migrations.AddIndex(
            model_name='bulkaccountdeleterequest',
            index=models.Index(fields=['status', 'expires_at'], name='apibulkdel_status_exp_idx'),
        ),
        migrations.AddIndex(
            model_name='devicesession',
            index=models.Index(fields=['user', '-last_seen_at'], name='apidevsess_user_seen_idx'),
        ),
        migrations.AddIndex(
            model_name='devicesession',
            index=models.Index(fields=['user', 'is_active'], name='apidevsess_user_active_idx'),
        ),
        migrations.AddIndex(
            model_name='passwordlessloginrequest',
            index=models.Index(fields=['user', '-created_at'], name='apipwless_user_created_idx'),
        ),
        migrations.AddIndex(
            model_name='passwordlessloginrequest',
            index=models.Index(fields=['status', 'expires_at'], name='apipwless_status_exp_idx'),
        ),
    ]
