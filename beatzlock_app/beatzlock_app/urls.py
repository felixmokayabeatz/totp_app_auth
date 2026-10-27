
from django.urls import path
from . import views

app_name = 'beatzlock_app'

urlpatterns = [
    path('account/', views.account, name='account'),

    path('downloads/', views.download_list, name='download_list'),
    path('downloads/archive/', views.archived_downloads, name='archived_downloads'),

    path('api/update-check/', views.update_check, name='update_check'),

    path('api/legal/<str:page_type>/', views.legal_document_json, name='legal_document_json'),
    path('rate/', views.rate_app, name='rate_app'),
    path('rate/<int:rating_id>/useful/', views.mark_rating_useful, name='mark_rating_useful_web'),
    path('api/ratings/', views.ratings_json, name='ratings_json'),
    path('api/ratings/me/', views.my_rating, name='my_rating'),
    path('api/ratings/submit/', views.submit_rating, name='submit_rating'),
    path('api/ratings/delete/', views.delete_rating, name='delete_rating'),
    path('api/ratings/<int:rating_id>/useful/', views.mark_rating_useful, name='mark_rating_useful'),

    path('download/<int:app_id>/', views.download_file, name='download_file'),

    path('release-notes/<int:app_id>/', views.release_notes_json, name='release_notes_json'),

    path('legal/terms-of-service/', views.legal_terms,   name='legal_terms'),
    path('legal/terms-of-service/archive/', views.legal_terms_archive, name='legal_terms_archive'),
    path('legal/terms-of-service/archive/<int:revision_id>/', views.legal_terms_revision, name='legal_terms_revision'),
    path('legal/privacy-policy/',   views.legal_privacy, name='legal_privacy'),
    path('legal/privacy-policy/archive/', views.legal_privacy_archive, name='legal_privacy_archive'),
    path('legal/privacy-policy/archive/<int:revision_id>/', views.legal_privacy_revision, name='legal_privacy_revision'),
]


