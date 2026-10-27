import os
from datetime import timedelta
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent

load_dotenv(BASE_DIR / '.env')

SECRET_KEY = os.getenv('DJANGO_SECRET_KEY') or os.getenv('SECRET_KEY')

DEBUG = os.getenv('DEBUG', 'False').lower() == 'true'

try:
    from .local import *
except ImportError:
    pass

SITE_DOMAIN = os.getenv('SITE_DOMAIN', 'api.example.com')
SITE_URL = os.getenv('SITE_URL', 'https://' + SITE_DOMAIN)


def _split_csv_env(*names):
    values = []
    for name in names:
        raw = os.getenv(name, '')
        if not raw:
            continue
        values.extend(part.strip() for part in raw.split(',') if part.strip())
    return values


if DEBUG:
    ALLOWED_HOSTS = ['*']
else:
    allowed_hosts = _split_csv_env('ALLOWED_HOSTS', 'DJANGO_ALLOWED_HOSTS')
    ALLOWED_HOSTS = list(dict.fromkeys(
        allowed_hosts + [
            host for host in (
                'localhost',
                '127.0.0.1',
                SITE_DOMAIN,
                os.getenv('SERVER_IP'),
            ) if host
        ]
    ))
    

EMAIL_BACKEND = os.getenv('EMAIL_BACKEND')
EMAIL_HOST = os.getenv('EMAIL_HOST')
EMAIL_PORT = int(os.getenv('EMAIL_PORT', 587))
EMAIL_USE_TLS = os.getenv('EMAIL_USE_TLS') == 'True'
EMAIL_HOST_USER = os.getenv('EMAIL_HOST_USER')
EMAIL_HOST_PASSWORD = os.getenv('EMAIL_HOST_PASSWORD')
EMAIL_TIMEOUT = int(os.getenv('EMAIL_TIMEOUT', 10))
SUPPORT_EMAIL = os.getenv('SUPPORT_EMAIL', '') or EMAIL_HOST_USER or ''
DEFAULT_FROM_EMAIL = (
    os.getenv('DEFAULT_FROM_EMAIL')
    or (f'BeatzLock Authenticator <{EMAIL_HOST_USER}>' if EMAIL_HOST_USER else None)
)
SERVER_EMAIL = DEFAULT_FROM_EMAIL
BEATZLOCK_INTERNAL_SERVICE_SECRET = os.getenv('BEATZLOCK_INTERNAL_SERVICE_SECRET', '')

AUTH_USER_MODEL = 'users.User'

INSTALLED_APPS = [
    'accounts',
    'users',
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'rest_framework',
    'rest_framework_simplejwt',
    'corsheaders',
    'api',
    'twofa',
    'beatzlocklogs',
    'django_extensions',
]

MIDDLEWARE = [
    'corsheaders.middleware.CorsMiddleware',
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

CORS_ALLOW_ALL_ORIGINS = True
CORS_ALLOW_CREDENTIALS = True

CORS_ALLOWED_ORIGINS = [
    "http://localhost:8000",
    "http://127.0.0.1:8000",
    "https://api.example.com",
    "http://api.example.com",
]

if DEBUG:
    CORS_ALLOWED_ORIGINS += [
        "http://localhost:8000",
        "http://127.0.0.1:8000",
        "https://api.example.com",
        "http://api.example.com",
    ]

CSRF_TRUSTED_ORIGINS = _split_csv_env('CSRF_TRUSTED_ORIGINS') or [SITE_URL]

SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

if not DEBUG:
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SESSION_COOKIE_HTTPONLY = True
    SECURE_SSL_REDIRECT = os.getenv('SECURE_SSL_REDIRECT', 'True').lower() == 'true'
    SECURE_HSTS_SECONDS = int(os.getenv('SECURE_HSTS_SECONDS', '15552000'))
    SECURE_HSTS_INCLUDE_SUBDOMAINS = (
        os.getenv('SECURE_HSTS_INCLUDE_SUBDOMAINS', 'False').lower() == 'true'
    )
    SECURE_HSTS_PRELOAD = (
        os.getenv('SECURE_HSTS_PRELOAD', 'False').lower() == 'true'
    )
    SECURE_CONTENT_TYPE_NOSNIFF = True
    SESSION_COOKIE_SAMESITE = 'Lax'
    CSRF_COOKIE_SAMESITE = 'Lax'

REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': (
        'api.authentication.DeviceSessionJWTAuthentication',
    ),
    'DEFAULT_PERMISSION_CLASSES': (
        'rest_framework.permissions.IsAuthenticated',
    ),
}

SIMPLE_JWT = {
    'ACCESS_TOKEN_LIFETIME': timedelta(minutes=60),
    'REFRESH_TOKEN_LIFETIME': timedelta(days=7),
}

ROOT_URLCONF = 'otp_backend.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [os.path.join(BASE_DIR, 'templates')],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'otp_backend.wsgi.application'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DJANGO_DB_NAME', 'felixmokayabeatz_totp_db'),
        'USER': os.getenv('DJANGO_DB_USER'),
        'PASSWORD': os.getenv('DJANGO_DB_PASSWORD'),
        'HOST': os.getenv('DJANGO_DB_HOST', 'localhost'),
        'PORT': (
            os.getenv('DJANGO_DB_PORT')
            or os.getenv('DJANGO_DB_PORT_POSTGRESQL')
            or '5432'
        ),
    }
}


AUTH_PASSWORD_VALIDATORS = [
    {
        'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator',
    },
]

LANGUAGE_CODE = 'en-us'
TIME_ZONE = os.getenv('TIME_ZONE', 'Africa/Nairobi')
USE_I18N = True
USE_TZ = True

MEDIA_URL = '/media/'
MEDIA_ROOT = os.path.join(BASE_DIR, 'media')

STATIC_URL = '/static/'

STATICFILES_DIRS = [
    BASE_DIR / "static",
]

STATIC_ROOT = os.path.join(BASE_DIR, 'staticfiles')


from .logging_config import get_logging_config

LOGGING = get_logging_config(DEBUG)
    
if DEBUG:
    print(f"DEBUG: {DEBUG}")
    print(f"ALLOWED_HOSTS: {ALLOWED_HOSTS}")
    print(f"EMAIL_BACKEND: {EMAIL_BACKEND}")
    print(f"EMAIL_HOST: {EMAIL_HOST}")
    print(f"EMAIL_PORT: {EMAIL_PORT}")
    print(f"EMAIL_USE_TLS: {EMAIL_USE_TLS}")
    print(f"EMAIL_TIMEOUT: {EMAIL_TIMEOUT}")
    print(f"EMAIL_HOST_USER: {EMAIL_HOST_USER}")
    print(f"EMAIL_HOST_PASSWORD: {'True' if EMAIL_HOST_PASSWORD else None}")
    print("==========The Db settings==========")
    print(f"DB_NAME: {os.getenv('DJANGO_DB_NAME')}")
    print(f"DB_USER: {os.getenv('DJANGO_DB_USER')}")    
    print(f"DB_PASSWORD: {'True' if os.getenv('DJANGO_DB_PASSWORD') else None}")
    print(f"DB_HOST: {os.getenv('DJANGO_DB_HOST')}")
    print("=" * 50)
    print("DEBUG MODE ENABLED - Verbose logging active")
    print(f"Logs directory: {BASE_DIR / 'logs'}")
    print("=" * 50)
