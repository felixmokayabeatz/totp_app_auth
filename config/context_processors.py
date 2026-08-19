from datetime import date

from django.conf import settings


def site_context(request):
    """Branding + analytics values the shared base template expects."""
    return {
        "site_name": settings.SITE_NAME,
        "site_url": settings.SITE_URL,
        "main_site_url": settings.MAIN_SITE_URL,
        "google_analytics_measurement_id": settings.GOOGLE_ANALYTICS_MEASUREMENT_ID,
        "current_year": date.today().year,
    }
