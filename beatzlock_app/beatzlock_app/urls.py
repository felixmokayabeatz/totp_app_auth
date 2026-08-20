#  beatzlock_app/urls.py

from django.urls import path
from . import views

app_name = 'beatzlock_app'

urlpatterns = [
    # Signed-in account: display name and profile image
    path('account/', views.account, name='account'),

    # Main download listing page
    path('downloads/', views.download_list, name='download_list'),
    path('downloads/archive/', views.archived_downloads, name='archived_downloads'),

    # Update check JSON for the native apps
    path('api/update-check/', views.update_check, name='update_check'),

    # Legal JSON consumed by the native BeatzLock app
    path('api/legal/<str:page_type>/', views.legal_document_json, name='legal_document_json'),
    path('rate/', views.rate_app, name='rate_app'),
    path('rate/<int:rating_id>/useful/', views.mark_rating_useful, name='mark_rating_useful_web'),
    path('api/ratings/', views.ratings_json, name='ratings_json'),
    path('api/ratings/me/', views.my_rating, name='my_rating'),
    path('api/ratings/submit/', views.submit_rating, name='submit_rating'),
    path('api/ratings/delete/', views.delete_rating, name='delete_rating'),
    path('api/ratings/<int:rating_id>/useful/', views.mark_rating_useful, name='mark_rating_useful'),

    # File download (triggers count + serves binary)
    path('download/<int:app_id>/', views.download_file, name='download_file'),

    # Release notes JSON â€” fetched by the modal
    path('release-notes/<int:app_id>/', views.release_notes_json, name='release_notes_json'),

    # Standalone legal pages â€” each at its own URL
    path('legal/terms-of-service/', views.legal_terms,   name='legal_terms'),
    path('legal/privacy-policy/',   views.legal_privacy, name='legal_privacy'),
]


