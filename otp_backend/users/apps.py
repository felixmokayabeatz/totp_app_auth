from django.apps import AppConfig


class UsersConfig(AppConfig):
    # auth_user.id has always been a plain integer column; BigAutoField would
    # ask for a type change on a table this app deliberately reuses as-is.
    default_auto_field = 'django.db.models.AutoField'
    name = 'users'
