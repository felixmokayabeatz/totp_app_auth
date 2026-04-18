# beatzlocklogs/urls.py

from django.urls import path
from . import views

app_name = 'beatzlocklogs'

urlpatterns = [
    path('', views.log_viewer, name='log_viewer'),
    path('<path:log_file>/', views.log_viewer, name='log_detail'),
]