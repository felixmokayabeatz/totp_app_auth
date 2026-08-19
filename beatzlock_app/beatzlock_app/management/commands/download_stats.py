from django.core.management.base import BaseCommand
from django.db.models import Sum

from beatzlock_app.models import DownloadableApp, DownloadStats, TotalDownloadCount


class Command(BaseCommand):
    help = 'Show aggregated download statistics by app and country'

    def handle(self, *args, **options):
        total = TotalDownloadCount.get_total()
        self.stdout.write(f"Total downloads: {total}")

        for app in DownloadableApp.objects.all().prefetch_related('stats'):
            app_total = app.stats.aggregate(total=Sum('download_count'))['total'] or 0
            self.stdout.write(f"{app.name} ({app.platform}): {app_total} downloads")

            for stat in app.stats.all().order_by('-download_count', 'country_name'):
                self.stdout.write(
                    f"  {stat.country_name} [{stat.country_code}]: {stat.download_count}"
                )

        top_countries = (
            DownloadStats.objects.values('country_name', 'country_code')
            .annotate(total=Sum('download_count'))
            .order_by('-total', 'country_name')[:10]
        )
        if top_countries:
            self.stdout.write("Top countries:")
            for country in top_countries:
                self.stdout.write(
                    f"  {country['country_name']} [{country['country_code']}]: {country['total']}"
                )
