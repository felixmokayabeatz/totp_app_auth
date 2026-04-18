# otp_backend/otp_backend/urls.py

from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from rest_framework.routers import DefaultRouter
from rest_framework_simplejwt.views import TokenRefreshView, TokenObtainPairView

from api.views import AuthViewSet, SyncViewSet, send_delete_otp, verify_delete_otp, set_sync_preference, get_sync_preference
from twofa.views import send_2fa_code, verify_2fa_code, send_password_reset_code, reset_password
from accounts.views import ProfileViewSet

from django.views.generic import RedirectView

router = DefaultRouter()
router.register(r'auth', AuthViewSet, basename='auth')
router.register(r'sync', SyncViewSet, basename='sync')
router.register(r'profile', ProfileViewSet, basename='profile')

urlpatterns = [
    # Admin
    path('admin/', admin.site.urls),
    
    # Log viewer - THIS IS THE IMPORTANT PART
    path('admin/logs/', include('beatzlocklogs.urls')),
    
    path('favicon.ico', RedirectView.as_view(url='/static/favicon.ico')),
    # API URLs
    path('api/', include(router.urls)),
    path('api/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),
    path('api/token/', TokenObtainPairView.as_view(), name='token_obtain_pair'),
    path('api/send-2fa/', send_2fa_code, name='send_2fa'),
    path('api/verify-2fa/', verify_2fa_code, name='verify_2fa'),
    path('api/send-reset-code/', send_password_reset_code, name='send_reset_code'),
    path('api/reset-password/', reset_password, name='reset_password'),
    path('api/send-delete-otp/', send_delete_otp, name='send_delete_otp'),
    path('api/verify-delete-otp/', verify_delete_otp, name='verify_delete_otp'),
    path('api/sync-preference/', set_sync_preference, name='set_sync_preference'),
    path('api/sync-preference/get/', get_sync_preference, name='get_sync_preference'),
] + static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)