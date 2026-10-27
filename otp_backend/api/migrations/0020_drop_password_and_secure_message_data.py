"""Delete the synced blobs for two features that no longer exist.

Passwords and secure self text were never their own tables -- they were rows in
``EncryptedData`` keyed by ``data_type``, which is why removing the features
touches no schema. The rows are still there though, and they are end-to-end
encrypted: nothing can read them, nothing will ever ask for them again, and
leaving them is keeping ciphertext for a feature that is gone.

Irreversible on purpose. The reverse would have to invent data it never had.
"""

from django.db import migrations

DROPPED_DATA_TYPES = ('password_entries', 'secure_messages')
DROPPED_NOTIFICATION_TYPES = ('secure_self_text',)


def drop_removed_feature_data(apps, schema_editor):
    EncryptedData = apps.get_model('api', 'EncryptedData')
    deleted, _ = EncryptedData.objects.filter(
        data_type__in=DROPPED_DATA_TYPES
    ).delete()
    if deleted:
        print(f'  Removed {deleted} stored blob(s) for withdrawn features.')

    AppNotification = apps.get_model('api', 'AppNotification')
    deleted, _ = AppNotification.objects.filter(
        notification_type__in=DROPPED_NOTIFICATION_TYPES
    ).delete()
    if deleted:
        print(f'  Removed {deleted} notification(s) for withdrawn features.')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0019_appnotification_apinotif_user_created_idx_and_more'),
    ]

    operations = [
        migrations.RunPython(
            drop_removed_feature_data,
            migrations.RunPython.noop,
        ),
    ]
