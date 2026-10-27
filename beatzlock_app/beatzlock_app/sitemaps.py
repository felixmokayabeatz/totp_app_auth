"""Sitemaps for apps.example.com.

The download listing, the ratings page and the two legal documents are the
public surface. Per-file download URLs are deliberately absent: they trigger a
counted download and serve a binary, so a crawler hitting them would inflate
the statistics and pull hundreds of megabytes.

The two archive *index* pages are listed. The individual archived revisions
are not, and they carry noindex: an old Terms is ~90% identical to the current
one, so indexing both invites Google to treat them as duplicates and rank the
wrong one. They stay reachable and crawlable for people; they just do not
compete in search.
"""
from django.contrib.sitemaps import Sitemap
from django.urls import reverse

from .models import LegalPage


class StaticViewSitemap(Sitemap):
    protocol = 'https'
    changefreq = 'weekly'

    pages = [
        ('beatzlock_app:download_list', 1.0),
        ('beatzlock_app:archived_downloads', 0.5),
        ('beatzlock_app:rate_app', 0.6),
    ]

    def items(self):
        return self.pages

    def location(self, item):
        return reverse(item[0])

    def priority(self, item):
        return item[1]


class LegalSitemap(Sitemap):
    """The live Terms and Privacy documents."""

    protocol = 'https'
    changefreq = 'monthly'
    priority = 0.5

    def items(self):
        items = []
        for page_type, url_name in (('terms', 'beatzlock_app:legal_terms'),
                                    ('privacy', 'beatzlock_app:legal_privacy')):
            if LegalPage.current(page_type) is not None:
                items.append(url_name)
        return items

    def location(self, item):
        return reverse(item)

    def lastmod(self, item):
        page_type = 'terms' if item.endswith('terms') else 'privacy'
        current = LegalPage.current(page_type)
        return current.effective_at if current else None


class LegalArchiveSitemap(Sitemap):
    """The two archive index pages. Individual revisions are noindex."""

    protocol = 'https'
    changefreq = 'yearly'
    priority = 0.2

    def items(self):
        items = []
        for page_type, index_name in (
            ('terms', 'beatzlock_app:legal_terms_archive'),
            ('privacy', 'beatzlock_app:legal_privacy_archive'),
        ):
            if LegalPage.archive_for(page_type):
                items.append(index_name)
        return items

    def location(self, item):
        return reverse(item)


sitemaps = {
    'static': StaticViewSitemap,
    'legal': LegalSitemap,
    'legal_archive': LegalArchiveSitemap,
}
