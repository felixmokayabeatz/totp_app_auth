from django.urls import path

from .build_history import build_history
from .download_stats import download_stats
from .review_replies import review_replies

urlpatterns = [
    path('stats/', download_stats, name='download_stats'),
    path('review-replies/', review_replies, name='review_replies'),
    path('build-history/', build_history, name='build_history'),
]
