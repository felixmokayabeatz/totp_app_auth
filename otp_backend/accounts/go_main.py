
from django.shortcuts import redirect
from django.conf import settings as django_settings

def go_to_main_site(request):
    print("DEBUG VALUE:", django_settings.DEBUG)

    if django_settings.DEBUG:
        print("Redirecting to LOCAL")
        return redirect('http://127.0.0.1:8002')

    print("Redirecting to PROD")
    return redirect('https://felixmokayabeatz.online')
