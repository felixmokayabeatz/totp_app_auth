from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from rest_framework.routers import DefaultRouter
from rest_framework_simplejwt.views import TokenRefreshView, TokenObtainPairView
from api.views import AuthViewSet, SyncViewSet
from twofa.views import send_2fa_code, verify_2fa_code, send_password_reset_code, reset_password
from accounts.views import ProfileViewSet

router = DefaultRouter()
router.register(r'auth', AuthViewSet, basename='auth')
router.register(r'sync', SyncViewSet, basename='sync')
router.register(r'profile', ProfileViewSet, basename='profile')

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include(router.urls)),
    path('api/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),
    path('api/token/', TokenObtainPairView.as_view(), name='token_obtain_pair'),
    path('api/send-2fa/', send_2fa_code, name='send_2fa'),
    path('api/verify-2fa/', verify_2fa_code, name='verify_2fa'),
    path('api/send-reset-code/', send_password_reset_code, name='send_reset_code'),
    path('api/reset-password/', reset_password, name='reset_password'),
] + static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)