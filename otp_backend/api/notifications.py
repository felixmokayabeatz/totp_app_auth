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
            "only if the 3-digit code matches what you see on that device."
        ),
        metadata={
            "requester_device_label": requester_device_label,
        },
    )


def create_bulk_delete_request_notification(
    user: User,
    *,
    requester_device_label: str,
    requested_count: int,
    range_start_date: str,
    range_end_date: str,
) -> AppNotification:
    message = (
        f"{requester_device_label} wants to delete "
        f"{requested_count} OTP account{'s' if requested_count != 1 else ''} everywhere."
    )
    details = (
        f"{requester_device_label} requested a cross-device OTP vault deletion for "
        f"{requested_count} account{'s' if requested_count != 1 else ''} "
        f"from {range_start_date} to {range_end_date}. Approve it only if you "
        "started that action yourself."
    )
    return create_notification(
        user,
        "bulk_delete_request",
        title="OTP delete approval request",
        message=message,
        details=details,
        metadata={
            "requester_device_label": requester_device_label,
            "requested_count": requested_count,
            "range_start_date": range_start_date,
            "range_end_date": range_end_date,
        },
    )


def create_backup_code_request_notification(
    user: User,
    *,
    requester_device_label: str,
) -> AppNotification:
    return create_notification(
        user,
        "backup_code_request",
        title="Backup codes requested",
        message=(
            f"{requester_device_label} asked your primary device to save the Recovery Codes PDF."
        ),
        details=(
            "Open BeatzLock on your primary device and approve the backup-code "
            "download so the Recovery Codes PDF is saved safely."
        ),
        metadata={
            "requester_device_label": requester_device_label,
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


def create_recovery_codes_generated_notification(
    user: User,
    *,
    device_label: str | None = None,
    generated_at: str | None = None,
) -> AppNotification:
    clean_label = device_label.strip() if device_label else ''
    generated_at_text = generated_at.strip() if generated_at else ''
    device_phrase = (
        f'from your primary device {clean_label}'
        if clean_label
        else 'from your primary device'
    )
    when_phrase = f' at {generated_at_text}' if generated_at_text else ''
    return create_notification(
        user,
        "recovery_codes_generated",
        title="New recovery codes generated",
        message=f"A new PDF with fresh recovery codes was generated {device_phrase}{when_phrase}.",
        details=(
            "A new set of BeatzLock recovery codes was generated for your account. "
            f"It was generated {device_phrase}{when_phrase}. "
            "All older recovery codes were invalidated immediately."
        ),
        metadata={
            "device_label": clean_label,
            "generated_at": generated_at_text,
        },
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


def create_accounts_imported_notification(
    user: User,
    *,
    imported_count: int,
    skipped_count: int = 0,
    source_label: str | None = None,
) -> AppNotification:
    source = source_label.strip() if source_label else ""
    source_suffix = f" from {source}" if source else ""
    message = (
        f"Imported {imported_count} OTP account{'s' if imported_count != 1 else ''}{source_suffix}."
    )
    details = (
        f"{imported_count} OTP account{'s were' if imported_count != 1 else ' was'} "
        f"imported into your BeatzLock vault{source_suffix}."
    )
    if skipped_count > 0:
        details = (
            f"{details} {skipped_count} duplicate"
            f"{'s were' if skipped_count != 1 else ' was'} skipped."
        )

    return create_notification(
        user,
        "accounts_imported",
        title="Accounts imported",
        message=message,
        details=details,
        metadata={
            "imported_count": imported_count,
            "skipped_count": skipped_count,
            "source_label": source or None,
        },
    )


def create_passwords_imported_notification(
    user: User,
    *,
    imported_count: int,
    source_label: str | None = None,
) -> AppNotification:
    source = source_label.strip() if source_label else ""
    source_suffix = f" from {source}" if source else ""
    message = (
        f"Imported {imported_count} secure item{'s' if imported_count != 1 else ''}{source_suffix}."
    )
    details = (
        f"{imported_count} secure password item{'s were' if imported_count != 1 else ' was'} "
        f"imported into your encrypted vault{source_suffix}."
    )

    return create_notification(
        user,
        "passwords_imported",
        title="Passwords imported",
        message=message,
        details=details,
        metadata={
            "imported_count": imported_count,
            "source_label": source or None,
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
