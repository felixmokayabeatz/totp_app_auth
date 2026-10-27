import logging
import os
from datetime import timedelta
from pathlib import Path

from django.conf import settings

from .models import DeviceSession

logger = logging.getLogger(__name__)

try:
    import firebase_admin
    from firebase_admin import credentials, messaging
except Exception:
    firebase_admin = None
    credentials = None
    messaging = None

_firebase_app = None
_firebase_init_attempted = False


def _push_result(
    *,
    dispatched: bool,
    reason: str,
    detail: str = '',
    message_id: str = '',
) -> dict[str, object]:
    return {
        'dispatched': dispatched,
        'reason': reason,
        'detail': detail,
        'message_id': message_id,
    }


def _candidate_service_account_paths() -> list[Path]:
    candidates: list[Path] = []

    explicit_path = os.getenv('FIREBASE_SERVICE_ACCOUNT_FILE', '').strip()
    if explicit_path:
        candidates.append(Path(explicit_path))

    repo_secrets_dir = Path(settings.BASE_DIR).parent / 'otp_auth_app' / 'secrets'
    if repo_secrets_dir.exists():
        candidates.extend(sorted(repo_secrets_dir.glob('*firebase-admin*.json')))
        candidates.extend(sorted(repo_secrets_dir.glob('*adminsdk*.json')))

    unique_candidates: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        normalized = str(candidate.resolve()) if candidate.exists() else str(candidate)
        if normalized in seen:
            continue
        seen.add(normalized)
        unique_candidates.append(candidate)
    return unique_candidates


def _resolve_service_account_path() -> Path | None:
    for candidate in _candidate_service_account_paths():
        if candidate.exists() and candidate.is_file():
            return candidate
    return None


def _get_firebase_app():
    global _firebase_app, _firebase_init_attempted

    if _firebase_app is not None:
        return _firebase_app

    if firebase_admin is None or credentials is None or messaging is None:
        logger.warning(
            'Firebase Admin SDK is not available. Install firebase-admin to enable passwordless push notifications.'
        )
        return None

    if _firebase_init_attempted:
        return None

    _firebase_init_attempted = True

    service_account_path = _resolve_service_account_path()
    if service_account_path is None:
        logger.info(
            'Firebase service-account JSON was not found. Passwordless push notifications are disabled.'
        )
        return None

    try:
        _firebase_app = firebase_admin.initialize_app(
            credentials.Certificate(str(service_account_path))
        )
    except ValueError:
        _firebase_app = firebase_admin.get_app()
    except Exception:
        logger.exception(
            'Firebase Admin initialization failed from %s.',
            service_account_path,
        )
        return None

    logger.info('Firebase Admin initialized for passwordless push notifications.')
    return _firebase_app


def send_passwordless_request_push(
    primary_session: DeviceSession,
    *,
    requester_device_label: str,
    request_id: str,
) -> dict[str, object]:
    push_token = (primary_session.push_token or '').strip()
    if not push_token:
        logger.info(
            'Skipping passwordless push for session %s because no push token is registered.',
            primary_session.id,
        )
        return _push_result(
            dispatched=False,
            reason='no_token',
            detail='This primary device has not registered a Firebase push token yet.',
        )

    if not primary_session.is_active or primary_session.revoked_at is not None:
        logger.info(
            'Skipping passwordless push for inactive or revoked session %s.',
            primary_session.id,
        )
        return _push_result(
            dispatched=False,
            reason='session_inactive',
            detail='The primary device session is inactive or already signed out.',
        )

    app = _get_firebase_app()
    if app is None or messaging is None:
        if firebase_admin is None or credentials is None or messaging is None:
            return _push_result(
                dispatched=False,
                reason='admin_sdk_missing',
                detail='firebase-admin is not installed on the backend.',
            )
        if _resolve_service_account_path() is None:
            return _push_result(
                dispatched=False,
                reason='service_account_missing',
                detail='The Firebase Admin service-account JSON was not found on the backend.',
            )
        return _push_result(
            dispatched=False,
            reason='firebase_unavailable',
            detail='Firebase Admin could not be initialized on the backend.',
        )

    device_label = requester_device_label.strip() or 'another device'
    title = 'Approve sign-in in BeatzLock'
    body = f'{device_label} is asking to sign in. Tap to open BeatzLock.'

    try:
        message_id = messaging.send(
            messaging.Message(
                token=push_token,
                notification=messaging.Notification(
                    title=title,
                    body=body,
                ),
                data={
                    'event': 'passwordless_request',
                    'action': 'open_passwordless_approvals',
                    'request_id': request_id,
                    'requester_device_label': device_label,
                    'title': title,
                    'body': body,
                },
                android=messaging.AndroidConfig(
                    priority='high',
                    ttl=timedelta(minutes=3),
                    notification=messaging.AndroidNotification(
                        channel_id='passwordless_approvals',
                        sound='default',
                    ),
                ),
            ),
            app=app,
        )
        return _push_result(
            dispatched=True,
            reason='sent',
            detail='Firebase accepted the passwordless wake-up notification.',
            message_id=message_id or '',
        )
    except Exception:
        logger.exception(
            'Firebase push send failed for passwordless request %s and session %s.',
            request_id,
            primary_session.id,
        )
        return _push_result(
            dispatched=False,
            reason='send_failed',
            detail='Firebase rejected or failed to deliver the wake-up notification request.',
        )
