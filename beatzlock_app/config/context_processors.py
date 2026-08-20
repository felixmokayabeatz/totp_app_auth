from datetime import date

from django.conf import settings


def site_context(request):
    """Branding + analytics values the shared base template expects."""
    return {
        "site_name": settings.SITE_NAME,
        "site_url": settings.SITE_URL,
        "main_site_url": settings.MAIN_SITE_URL,
        "site_tagline": settings.SITE_TAGLINE,
        "fmb_site_links": settings.FMB_SITE_LINKS,
        "google_enabled": bool(settings.GOOGLE_CLIENT_ID and settings.GOOGLE_CLIENT_SECRET),
        "google_analytics_measurement_id": settings.GOOGLE_ANALYTICS_MEASUREMENT_ID,
        "current_year": date.today().year,
    }
