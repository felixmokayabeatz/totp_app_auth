import base64
import hashlib
import json
from datetime import timedelta
from typing import Any

from cryptography.fernet import Fernet
from django.conf import settings
from django.contrib.auth.models import User
from django.utils import timezone

from .models import AppNotification


def _get_cipher() -> Fernet:
    digest = hashlib.sha256(
        f"beatzlock-notifications|{settings.SECRET_KEY}".encode("utf-8")
    ).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt_notification_payload(payload: dict[str, Any]) -> str:
    return _get_cipher().encrypt(
        json.dumps(payload).encode("utf-8")
    ).decode("utf-8")


def decrypt_notification_payload(payload: str) -> dict[str, Any]:
    return json.loads(
        _get_cipher().decrypt(payload.encode("utf-8")).decode("utf-8")
    )


def build_device_label(device_label: str | None, user_agent: str | None) -> str:
    if device_label and device_label.strip():
        return device_label.strip()
    if user_agent and user_agent.strip():
        lowered = user_agent.strip().lower()
        if lowered.startswith("dart/"):
            return "BeatzLock App"
        return user_agent.strip()[:120]
    return "Unknown device"


def create_notification(
    user: User,
    notification_type: str,
    *,
    title: str,
    message: str,
    details: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> AppNotification:
    payload = {
        "title": title,
        "message": message,
        "details": details or message,
        "metadata": metadata or {},
    }
    notification = AppNotification.objects.create(
        user=user,
        notification_type=notification_type,
        encrypted_payload=encrypt_notification_payload(payload),
    )

    excess_ids = list(
        AppNotification.objects.filter(user=user)
        .order_by("-created_at")
        .values_list("id", flat=True)[100:]
    )
    if excess_ids:
        AppNotification.objects.filter(id__in=excess_ids).delete()

    return notification


def create_sign_in_notification(user: User, device_label: str) -> AppNotification:
    return create_notification(
        user,
        "sign_in",
        title="Signed in on a device",
        message=f"You signed in on {device_label}.",
        details=(
            f"A successful BeatzLock sign-in happened on {device_label}. "
            "If this was not you, change your password immediately."
        ),
        metadata={"device_label": device_label},
    )


def create_passwordless_request_notification(
    user: User,
    *,
    requester_device_label: str,
    verification_code: str,
) -> AppNotification:
    return create_notification(
        user,
        "passwordless_request",
        title="New passwordless sign-in request",
        message=(
            f"A device named {requester_device_label} is asking to sign in."
        ),
        details=(
            f"Approve the passwordless sign-in request for {requester_device_label} "
            f"only if the 3-3 code matches: {verification_code}."
        ),
        metadata={
            "requester_device_label": requester_device_label,
            "verification_code": verification_code,
        },
    )


def create_password_changed_notification(
    user: User,
    *,
    source: str,
    device_label: str | None = None,
) -> AppNotification:
    details = f"Your BeatzLock password was changed via {source}."
    if device_label:
        details = f"{details} Device: {device_label}."

    return create_notification(
        user,
        "password_changed",
        title="Password changed",
        message="Your account password was updated successfully.",
        details=details,
        metadata={
            "source": source,
            "device_label": device_label,
        },
    )


def create_recovery_code_used_notification(
    user: User,
    *,
    purpose: str,
    device_label: str | None = None,
) -> AppNotification:
    details = f"A recovery code was used to {purpose}."
    if device_label:
        details = f"{details} Device: {device_label}."

    return create_notification(
        user,
        "recovery_code_used",
        title="Recovery code used",
        message=f"A recovery code was used to {purpose}.",
        details=details,
        metadata={
            "purpose": purpose,
            "device_label": device_label,
        },
    )


def create_recovery_codes_generated_notification(user: User) -> AppNotification:
    return create_notification(
        user,
        "recovery_codes_generated",
        title="New recovery codes generated",
        message="A new PDF with fresh recovery codes was generated.",
        details=(
            "A new set of BeatzLock recovery codes was generated for your account. "
            "All older recovery codes were invalidated immediately."
        ),
    )


def create_account_added_notification(
    user: User,
    *,
    service_name: str,
    account_label: str | None = None,
) -> AppNotification:
    label = account_label.strip() if account_label else ""
    message = f"You added {service_name} to BeatzLock."
    details = (
        f"A new OTP account for {service_name} was added to your vault."
        if not label
        else f"A new OTP account for {service_name} ({label}) was added to your vault."
    )

    return create_notification(
        user,
        "account_added",
        title="Account added",
        message=message,
        details=details,
        metadata={
            "service_name": service_name,
            "account_label": label or None,
        },
    )


def create_app_pin_changed_notification(
    user: User,
    *,
    device_label: str | None = None,
) -> AppNotification:
    details = "Your BeatzLock app PIN was changed."
    message = "Your BeatzLock app unlock PIN was changed."
    if device_label:
        details = f"{details} Device: {device_label}."
        message = f"Your BeatzLock app unlock PIN was changed on {device_label}."

    return create_notification(
        user,
        "app_pin_changed",
        title="App PIN changed",
        message=message,
        details=details,
        metadata={"device_label": device_label},
    )


def create_daily_active_devices_notification(
    user: User,
    *,
    active_count: int,
) -> AppNotification | None:
    now = timezone.now()
    recent_exists = AppNotification.objects.filter(
        user=user,
        notification_type='active_devices_daily',
        created_at__gte=now - timedelta(hours=24),
    ).exists()

    if recent_exists:
        return None

    device_word = 'device' if active_count == 1 else 'devices'
    return create_notification(
        user,
        'active_devices_daily',
        title='Daily device activity',
        message=f'{active_count} {device_word} are currently signed in to your account.',
        details=(
            f'BeatzLock checked your account and found {active_count} active {device_word} '
            'signed in during the last daily security summary.'
        ),
        metadata={'active_count': active_count},
    )


def create_app_review_reply_notification(
    user: User,
    *,
    platform_label: str,
    stars: int,
    admin_reply: str,
    display_name: str | None = None,
) -> AppNotification:
    reviewer_name = (display_name or '').strip() or 'Anonymous user'
    return create_notification(
        user,
        'app_review_reply',
        title='Reply to your BeatzLock review',
        message=f'BeatzLock replied to your {platform_label} review.',
        details=(
            f'Your {stars}-star review on {platform_label} received a reply. '
            f'Reviewer name: {reviewer_name}. '
            f'Reply: {admin_reply}'
        ),
        metadata={
            'platform_label': platform_label,
            'stars': stars,
            'display_name': reviewer_name,
            'admin_reply': admin_reply,
        },
    )
