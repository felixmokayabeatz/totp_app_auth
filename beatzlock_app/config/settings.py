"""
Settings for the standalone BeatzLock apps site.

Runs on its own database and its own subdomain, fully independent of the
felixmokayabeatz main site.
"""
import os
from datetime import datetime
from pathlib import Path

import dj_database_url
from dotenv import load_dotenv

# ====================
# PATH CONFIGURATION
# ====================

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")


def env_bool(name, default=False):
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def env_list(name, default=""):
    return [item.strip() for item in os.getenv(name, default).split(",") if item.strip()]


# ====================
# CORE CONFIGURATION
# ====================

SECRET_KEY = os.getenv("DJANGO_SECRET_KEY")
DEBUG = env_bool("DEBUG", False)

# ====================================================================
# Local settings for development
#
# Sits here, straight after DEBUG and before anything derived from it, for the
# same reason the API's copy does: the static storage, the middleware and the
# cookie flags below are all decided by DEBUG, so an override that arrived
# later would leave them set for production. Per-machine values that are not
# DEBUG -- database credentials, ports, hosts -- belong in .env, which is
# per-machine already.
#
# local.py is git-ignored and dev-only. deploy/deploy.sh refuses to run on any
# host where it exists, because it would quietly serve the site with DEBUG=True.
# ====================================================================
try:
    from .local import *  # noqa: F401,F403
except ImportError:
    pass

SITE_DOMAIN = os.getenv("SITE_DOMAIN", "apps.felixmokayabeatz.online")
SITE_URL = os.getenv("SITE_URL", "https://" + SITE_DOMAIN)

ALLOWED_HOSTS = env_list("ALLOWED_HOSTS", SITE_DOMAIN)
if DEBUG:
    ALLOWED_HOSTS = ["*"]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"
ASGI_APPLICATION = "config.asgi.application"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# ========================
# APPLICATION DEFINITION
# ========================

INSTALLED_APPS = [
    # console comes first only so that its management/commands/createsuperuser.py
    # wins over django.contrib.auth's: Django resolves a duplicated command name
    # to whichever app is listed earlier. beatzlock_app has to stay *after*
    # django.contrib.auth, on the other hand, because its admin module
    # unregisters the User admin that django.contrib.auth registers.
    "console",
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.humanize",
    "corsheaders",
    "beatzlock_app",
]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    # WhiteNoise serves the collectstatic output, which does not exist until
    # collectstatic has run -- so in development it only warns "No directory at:
    # .../staticfiles/" on every start. runserver's own staticfiles app serves
    # those files straight from the apps there, so WhiteNoise is loaded in
    # production only, where deploy.sh has run collectstatic.
    *([] if DEBUG else ["whitenoise.middleware.WhiteNoiseMiddleware"]),
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

# ========================
# TEMPLATES CONFIGURATION
# ========================

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
                "config.context_processors.site_context",
            ],
        },
    },
]

# ========================
# DATABASE CONFIGURATION
# ========================

DATABASE_URL = os.getenv("DATABASE_URL")

if DATABASE_URL:
    DATABASES = {"default": dj_database_url.config(default=DATABASE_URL)}
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": os.getenv("DJANGO_DB_NAME", "felixmokayabeatz_beatzlock_db"),
            "USER": os.getenv("DJANGO_DB_USER"),
            "PASSWORD": os.getenv("DJANGO_DB_PASSWORD"),
            "HOST": os.getenv("DJANGO_DB_HOST", "localhost"),
            "PORT": os.getenv("DJANGO_DB_PORT", "5432"),
        }
    }

# ==============================
# AUTHENTICATION CONFIGURATION
# ==============================

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LOGIN_URL = "/accounts/login/"
LOGIN_REDIRECT_URL = "/"
LOGOUT_REDIRECT_URL = "/"

# =============================
# STATIC & MEDIA CONFIGURATION
# =============================

STATIC_URL = "/staticfiles/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "static"]
# The hashed manifest needs collectstatic to have run, so it is production-only.
_STATICFILES_BACKEND = (
    "django.contrib.staticfiles.storage.StaticFilesStorage"
    if DEBUG
    else "whitenoise.storage.CompressedManifestStaticFilesStorage"
)
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": _STATICFILES_BACKEND},
}

MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

# App binaries are handed to nginx via X-Accel-Redirect in production so
# Gunicorn workers never stream large download payloads.
USE_X_ACCEL_REDIRECT = env_bool("USE_X_ACCEL_REDIRECT", not DEBUG)

# ========================
# EMAIL CONFIGURATION
# ========================

EMAIL_BACKEND = os.getenv("EMAIL_BACKEND", "django.core.mail.backends.smtp.EmailBackend")
EMAIL_HOST = os.getenv("EMAIL_HOST")
EMAIL_PORT = int(os.getenv("EMAIL_PORT", 587))
EMAIL_USE_TLS = env_bool("EMAIL_USE_TLS", True)
EMAIL_HOST_USER = os.getenv("EMAIL_HOST_USER")
EMAIL_HOST_PASSWORD = os.getenv("EMAIL_HOST_PASSWORD")
EMAIL_TIMEOUT = int(os.getenv("EMAIL_TIMEOUT", 10))
SUPPORT_EMAIL = os.getenv("SUPPORT_EMAIL", "")
DEFAULT_FROM_EMAIL = os.getenv("DEFAULT_FROM_EMAIL") or "BeatzLock Authenticator <{}>".format(
    EMAIL_HOST_USER or SUPPORT_EMAIL
)

# ================================
# BEATZLOCK SERVICE CONFIGURATION
# ================================

# ==========================================
# GOOGLE SIGN-IN
# ==========================================
# Client ID and secret come from the Google Cloud console, project credentials.
# The redirect URI is built from the request at run time, so the only thing that
# has to match there is the callback path:
#   https://apps.felixmokayabeatz.online/accounts/google/callback/
#   http://localhost:8005/accounts/google/callback/   (development)
GOOGLE_CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID", "")
GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET", "")

BEATZLOCK_API_BASE_URL = os.getenv("BEATZLOCK_API_BASE_URL", "")
BEATZLOCK_INTERNAL_SERVICE_SECRET = os.getenv("BEATZLOCK_INTERNAL_SERVICE_SECRET", "")
BEATZLOCK_BUILD_LOGS_DIR = os.getenv("BEATZLOCK_BUILD_LOGS_DIR", "")

# ===========================
# SECURITY CONFIGURATION
# ===========================

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
CSRF_TRUSTED_ORIGINS = env_list("CSRF_TRUSTED_ORIGINS", SITE_URL)

# The native BeatzLock apps call the JSON endpoints on this host.
CORS_ALLOW_CREDENTIALS = True
CORS_ALLOWED_ORIGINS = env_list("CORS_ALLOWED_ORIGINS", SITE_URL)

if not DEBUG:
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_CONTENT_TYPE_NOSNIFF = True

# =======================
# INTERNATIONALIZATION
# =======================

LANGUAGE_CODE = "en-us"
TIME_ZONE = os.getenv("TIME_ZONE", "Africa/Nairobi")
USE_I18N = True
USE_TZ = True

# ========================
# UPLOAD CONFIGURATION
# ========================

DATA_UPLOAD_MAX_MEMORY_SIZE = 52428800

# Django's default, deliberately: anything larger than this is streamed to a
# temporary file instead of being held in the worker's memory. App binaries are
# hundreds of megabytes, and at the previous 50MB three workers could hold
# 150MB of upload in RAM between them -- enough to get one of them OOM-killed
# on a small host, which drops the connection mid-upload with no response.
FILE_UPLOAD_MAX_MEMORY_SIZE = 2621440

# ========================
# BRANDING (template use)
# ========================

SITE_NAME = os.getenv("SITE_NAME", "BeatzLock Apps")
MAIN_SITE_URL = os.getenv("MAIN_SITE_URL", "https://felixmokayabeatz.online")
SITE_TAGLINE = os.getenv(
    "SITE_TAGLINE",
    "The BeatzLock Authenticator: downloads, release notes and reviews, "
    "straight from the people who build it.",
)

# The other felixmokayabeatz sites, listed in the footer. Each is its own
# project on its own subdomain, so each URL can be pointed elsewhere from .env
# without touching the template.
FMB_SITE_LINKS = [
    {"name": "Main site", "url": MAIN_SITE_URL, "icon": "fa-house"},
    {"name": "Blog", "url": os.getenv("BLOG_URL", "https://blog.felixmokayabeatz.online"), "icon": "fa-feather-pointed"},
    {"name": "Portfolio", "url": os.getenv("PORTFOLIO_URL", "https://portfolio.felixmokayabeatz.online"), "icon": "fa-briefcase"},
    {"name": "Invoices", "url": os.getenv("INVOICES_URL", "https://invoices.felixmokayabeatz.online"), "icon": "fa-file-invoice"},
]
GOOGLE_ANALYTICS_MEASUREMENT_ID = os.getenv("GOOGLE_ANALYTICS_MEASUREMENT_ID", "")

# ========================
# LOGGING CONFIGURATION
# ========================

_now = datetime.now()
LOG_DIR = BASE_DIR / "logs" / str(_now.year) / "week_{:02d}".format(_now.isocalendar().week)
LOG_DIR.mkdir(parents=True, exist_ok=True)
_log_date = _now.strftime("%Y-%m-%d")

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "verbose": {
            "format": "[{asctime}] {levelname} {name}: {message}",
            "style": "{",
            "datefmt": "%Y-%m-%d %H:%M:%S",
        },
    },
    "handlers": {
        "console": {"level": "INFO", "class": "logging.StreamHandler", "formatter": "verbose"},
        "file_info": {
            "level": "INFO",
            "class": "logging.handlers.RotatingFileHandler",
            "filename": str(LOG_DIR / "info_{}.log".format(_log_date)),
            "maxBytes": 10 * 1024 * 1024,
            "backupCount": 5,
            "formatter": "verbose",
        },
        "file_error": {
            "level": "ERROR",
            "class": "logging.handlers.RotatingFileHandler",
            "filename": str(LOG_DIR / "errors_{}.log".format(_log_date)),
            "maxBytes": 10 * 1024 * 1024,
            "backupCount": 5,
            "formatter": "verbose",
        },
    },
    "root": {"handlers": ["console", "file_info", "file_error"], "level": "INFO"},
    "loggers": {
        "beatzlock_app": {
            "handlers": ["console", "file_info", "file_error"],
            "level": "INFO",
            "propagate": False,
        },
    },
}
