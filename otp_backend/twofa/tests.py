import os
import sys
import django
from pathlib import Path
from dotenv import load_dotenv

# Paths
BASE_DIR = Path(__file__).resolve().parent.parent

# Add project to path
sys.path.append(str(BASE_DIR))

# Load .env
load_dotenv(BASE_DIR / ".env")

# Django setup (FIXED PATH)
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "otp_backend.settings")
django.setup()

# Imports AFTER setup
from django.core.mail import send_mail
from django.conf import settings

# Send email
try:
    send_mail(
        subject="Test Email",
        message="This is a test email from OTP Authenticator",
        from_email=settings.EMAIL_HOST_USER,
        recipient_list=["ecopiboe@gmail.com"],
        fail_silently=False,
    )
    print("✅ Email sent successfully!")
except Exception as e:
    print(f"❌ Email failed: {e}")