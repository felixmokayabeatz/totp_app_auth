import os
from datetime import timedelta
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.getenv('SECRET_KEY')

DEBUG = os.getenv('DEBUG', 'False').lower() == 'true'

#====================================================================
# Local settings for development
try:
    from .local import *
except ImportError:
    pass
#====================================================================

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
    # '153.75.247.17' accepts requests that reach the server by bare IP instead of
    # the domain; without it those hit DisallowedHost before any view runs.
    ALLOWED_HOSTS = list(dict.fromkeys(
        allowed_hosts + [
            'localhost',
            '127.0.0.1',
            'api.felixmokayabeatz.online',
            '153.75.247.17',
        ]
    ))
    

EMAIL_BACKEND = os.getenv('EMAIL_BACKEND')
EMAIL_HOST = os.getenv('EMAIL_HOST')
EMAIL_PORT = int(os.getenv('EMAIL_PORT', 587))
EMAIL_USE_TLS = os.getenv('EMAIL_USE_TLS') == 'True'
EMAIL_HOST_USER = os.getenv('EMAIL_HOST_USER')
EMAIL_HOST_PASSWORD = os.getenv('EMAIL_HOST_PASSWORD')
SUPPORT_EMAIL = os.getenv('SUPPORT_EMAIL', 'felixmokayabeatz@proton.me')
DEFAULT_FROM_EMAIL = (
    os.getenv('DEFAULT_FROM_EMAIL')
    or (f'BeatzLock Authenticator <{EMAIL_HOST_USER}>' if EMAIL_HOST_USER else None)
)
SERVER_EMAIL = DEFAULT_FROM_EMAIL
BEATZLOCK_INTERNAL_SERVICE_SECRET = os.getenv('BEATZLOCK_INTERNAL_SERVICE_SECRET', '')

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'rest_framework',
    'rest_framework_simplejwt',
    'corsheaders',
    'accounts',
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
    "https://api.felixmokayabeatz.online",
    "http://api.felixmokayabeatz.online",
]

if DEBUG:
    CORS_ALLOWED_ORIGINS += [
        "http://localhost:8000",
        "http://127.0.0.1:8000",
        "https://api.felixmokayabeatz.online",
        "http://api.felixmokayabeatz.online",
    ]

CSRF_TRUSTED_ORIGINS = [
    "https://api.felixmokayabeatz.online",
]

SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

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
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': '/home/felixmokayabeatz/Uploads/home/felixmokayabeatz/backups/2026/week_21/totp_db_2026-05-18_21-05-04.sqlite3',
    }
}

# DATABASES = {
#     'default': {
#         'ENGINE': 'django.db.backends.postgresql',
#         'NAME': os.getenv('DJANGO_DB_NAME'),
#         'USER': os.getenv('DJANGO_DB_USER'),
#         'PASSWORD': os.getenv('DJANGO_DB_PASSWORD'),
#         'HOST': os.getenv('DJANGO_DB_HOST'),
#         'PORT': os.getenv('DJANGO_DB_PORT_POSTGRESQL'),
#     }
# }


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
TIME_ZONE = 'Africa/Nairobi'
USE_I18N = True
USE_TZ = True

MEDIA_URL = '/media/'
MEDIA_ROOT = os.path.join(BASE_DIR, 'media')

STATIC_URL = '/static/'

STATICFILES_DIRS = [
    BASE_DIR / "static",
]

STATIC_ROOT = os.path.join(BASE_DIR, 'staticfiles')


# ===================
# LOGGING CONFIGURATION
# ===================
from .logging_config import get_logging_config

# Setup logging
LOGGING = get_logging_config(DEBUG)
    
if DEBUG:
    print(f"DEBUG: {DEBUG}")
    print(f"ALLOWED_HOSTS: {ALLOWED_HOSTS}")
    print(f"EMAIL_BACKEND: {EMAIL_BACKEND}")
    print(f"EMAIL_HOST: {EMAIL_HOST}")
    print(f"EMAIL_PORT: {EMAIL_PORT}")
    print(f"EMAIL_USE_TLS: {EMAIL_USE_TLS}")
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
