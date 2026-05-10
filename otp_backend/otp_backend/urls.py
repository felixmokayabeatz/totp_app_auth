# otp_backend/otp_backend/urls.py

from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from rest_framework.routers import DefaultRouter
from rest_framework_simplejwt.views import TokenObtainPairView

from api.views import (
    AppNotificationViewSet,
    AuthViewSet,
    BackupCodeGenerationRequestViewSet,
    BulkAccountDeleteRequestViewSet,
    DeviceSessionViewSet,
    PasswordlessLoginRequestViewSet,
    SyncViewSet,
    send_delete_otp,
    verify_delete_otp,
    set_sync_preference,
    get_sync_preference,
    download_backup_codes,
    get_backup_code_status,
    receive_external_review_reply,
)
from api.token_views import DeviceSessionTokenRefreshView
from twofa.views import (
    send_2fa_code,
    verify_2fa_code,
    send_password_reset_code,
    reset_password,
    check_recovery_email,
    verify_recovery_code_login,
    reset_password_with_recovery_code,
)
from accounts.views import ProfileViewSet

from django.views.generic import RedirectView

from django.conf.urls import handler404
from accounts.views import custom_404_view

handler404 = custom_404_view

router = DefaultRouter()
router.register(r'auth', AuthViewSet, basename='auth')
router.register(r'sync', SyncViewSet, basename='sync')
router.register(r'notifications', AppNotificationViewSet, basename='notifications')
router.register(r'device-sessions', DeviceSessionViewSet, basename='device-sessions')
router.register(r'passwordless-requests', PasswordlessLoginRequestViewSet, basename='passwordless-requests')
router.register(r'bulk-delete-requests', BulkAccountDeleteRequestViewSet, basename='bulk-delete-requests')
router.register(r'backup-code-requests', BackupCodeGenerationRequestViewSet, basename='backup-code-requests')
router.register(r'profile', ProfileViewSet, basename='profile')

urlpatterns = [
    # Admin
    path('admin/', admin.site.urls),
    
    # Log viewer - THIS IS THE IMPORTANT PART
    path('admin/logs/', include('beatzlocklogs.urls')),
    
    path('favicon.ico', RedirectView.as_view(url='/static/favicon.ico')),
    # API URLs
    path('api/', include(router.urls)),
    path('api/token/refresh/', DeviceSessionTokenRefreshView.as_view(), name='token_refresh'),
    path('api/token/', TokenObtainPairView.as_view(), name='token_obtain_pair'),
    path('api/send-2fa/', send_2fa_code, name='send_2fa'),
    path('api/verify-2fa/', verify_2fa_code, name='verify_2fa'),
    path('api/send-reset-code/', send_password_reset_code, name='send_reset_code'),
    path('api/reset-password/', reset_password, name='reset_password'),
    path('api/recovery-code/check-email/', check_recovery_email, name='check_recovery_email'),
    path('api/recovery-code/login/', verify_recovery_code_login, name='verify_recovery_code_login'),
    path('api/recovery-code/reset-password/', reset_password_with_recovery_code, name='reset_password_with_recovery_code'),
    path('api/send-delete-otp/', send_delete_otp, name='send_delete_otp'),
    path('api/verify-delete-otp/', verify_delete_otp, name='verify_delete_otp'),
    path('api/sync-preference/', set_sync_preference, name='set_sync_preference'),
    path('api/sync-preference/get/', get_sync_preference, name='get_sync_preference'),
    path('api/backup-codes/download/', download_backup_codes, name='download_backup_codes'),
    path('api/backup-codes/status/', get_backup_code_status, name='get_backup_code_status'),
    path('api/external/review-reply/', receive_external_review_reply, name='receive_external_review_reply'),
] + static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
