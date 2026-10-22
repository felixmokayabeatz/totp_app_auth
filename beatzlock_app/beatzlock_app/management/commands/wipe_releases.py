from django.core.management.base import BaseCommand
from django.db import transaction

from beatzlock_app.models import AppRelease, DownloadableApp


class Command(BaseCommand):
    help = (
        "Delete every AppRelease and DownloadableApp row, including their "
        "uploaded binaries and release-notes files, ahead of a fresh version "
        "reset. Run this once on the server, then create a single new "
        "AppRelease/DownloadableApp for the new version through the admin."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--yes',
            action='store_true',
            help="Skip the confirmation prompt (for non-interactive use).",
        )

    def handle(self, *args, **options):
        builds = list(DownloadableApp.objects.select_related('release').order_by('-created_at'))
        releases = list(AppRelease.objects.order_by('-released_at'))

        if not builds and not releases:
            self.stdout.write(self.style.WARNING('Nothing to delete — no releases or builds exist.'))
            return

        self.stdout.write('This will permanently delete:')
        for build in builds:
            self.stdout.write(
                f"  build: {build.name} [{build.get_platform_display()}] "
                f"v{build.version or 'unassigned'} — {build.file.name or '(no file)'}"
            )
        for release in releases:
            self.stdout.write(
                f"  release: v{release.version} "
                f"(build {release.build_number or '-'}) — "
                f"{release.release_notes_file.name or '(no release notes file)'}"
            )

        self.stdout.write(
            self.style.WARNING(
                '\nDownloadStats and DownloadDailyStat rows for these builds are '
                'deleted too (CASCADE) — per-build download history goes with '
                'them. The global TotalDownloadCount counter and AppRating '
                'reviews are left untouched.'
            )
        )

        if not options['yes']:
            answer = input("\nType 'yes' to permanently delete all of the above: ").strip().lower()
            if answer != 'yes':
                self.stdout.write(self.style.ERROR('Aborted — nothing was deleted.'))
                return

        with transaction.atomic():
            for build in builds:
                build.delete()
            for release in releases:
                release.delete()

        self.stdout.write(
            self.style.SUCCESS(
                f'Deleted {len(builds)} build(s) and {len(releases)} release(s).'
            )
        )
