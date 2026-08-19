import logging

import requests
from django.conf import settings
from django.core.mail import EmailMultiAlternatives
from django.template.loader import render_to_string
from django.utils import timezone

logger = logging.getLogger(__name__)


def _from_email():
    return getattr(settings, 'DEFAULT_FROM_EMAIL', '') or settings.EMAIL_HOST_USER or None


def _support_email():
    return getattr(settings, 'SUPPORT_EMAIL', '') or getattr(settings, 'EMAIL_HOST_USER', '') or ''


def _notification_bridge_url(base_url: str) -> str:
    return f"{base_url.rstrip('/')}/external/review-reply/"


def _review_snapshot(rating, platform='', entry=None, reply_text=''):
    platform = rating.normalize_platform(platform or rating.platform)
    entry = dict(entry or rating.get_platform_review(platform) or {})

    return {
        'platform': platform,
        'platform_label': rating.platform_label_for(platform),
        'stars': int(entry.get('stars') or rating.stars or 1),
        'comment': str(entry.get('comment') or rating.comment or ''),
        'suggestion': str(entry.get('suggestion') or rating.suggestion or ''),
        'admin_reply': str(reply_text or entry.get('admin_reply') or rating.admin_reply or ''),
        'display_name': rating.display_name_or_anonymous,
        'account_email': (rating.account_email or '').strip(),
        'account_user_id': str(rating.account_user_id or '').strip(),
    }


def _reply_email_subject(snapshot):
    return f"BeatzLock replied to your {snapshot['platform_label']} review"


def _reply_email_text(snapshot):
    greeting = snapshot['display_name']
    return (
        f"Hello {greeting},\n\n"
        f"Thanks for rating BeatzLock on {snapshot['platform_label']}. "
        "A BeatzLock admin has replied to your review.\n\n"
        f"Your rating: {snapshot['stars']}/5\n"
        f"Comment: {snapshot['comment'] or 'No comment shared.'}\n"
        f"Suggestion: {snapshot['suggestion'] or 'No suggestion shared.'}\n\n"
        f"Reply:\n{snapshot['admin_reply']}\n\n"
        "You will also see this reply inside the BeatzLock app notifications if you are signed in."
    )


def _reply_email_context(snapshot):
    return {
        'display_name': snapshot['display_name'],
        'platform_label': snapshot['platform_label'],
        'stars': snapshot['stars'],
        'comment': snapshot['comment'] or 'No comment shared.',
        'suggestion': snapshot['suggestion'] or 'No suggestion shared.',
        'admin_reply': snapshot['admin_reply'],
        'current_year': timezone.now().year,
        'support_email': _support_email(),
        'subject': _reply_email_subject(snapshot),
    }


def _reply_email_html(snapshot):
    return render_to_string(
        'beatzlock_app/emails/review_reply_email.html',
        _reply_email_context(snapshot),
    )


def send_review_reply_email(snapshot):
    recipient = snapshot['account_email']
    if not recipient:
        return False, 'No account email stored for this review.'

    email = EmailMultiAlternatives(
        subject=_reply_email_subject(snapshot),
        body=_reply_email_text(snapshot),
        from_email=_from_email(),
        to=[recipient],
        reply_to=[_support_email()] if _support_email() else None,
        headers={
            'X-Auto-Response-Suppress': 'All',
            'Auto-Submitted': 'auto-generated',
        },
    )
    email.attach_alternative(_reply_email_html(snapshot), 'text/html')
    email.send(fail_silently=False)
    return True, ''


def send_review_reply_notification(snapshot):
    base_url = getattr(settings, 'BEATZLOCK_API_BASE_URL', '').strip()
    shared_secret = getattr(settings, 'BEATZLOCK_INTERNAL_SERVICE_SECRET', '').strip()
    if not base_url or not shared_secret:
        return False, 'BeatzLock API notification bridge is not configured.'

    response = requests.post(
        _notification_bridge_url(base_url),
        json={
            'user_id': snapshot['account_user_id'],
            'email': snapshot['account_email'],
            'platform_label': snapshot['platform_label'],
            'stars': snapshot['stars'],
            'display_name': snapshot['display_name'],
            'admin_reply': snapshot['admin_reply'],
        },
        headers={'X-BeatzLock-Service-Secret': shared_secret},
        timeout=20,
    )
    response.raise_for_status()
    return True, ''


def dispatch_review_reply(rating, *, platform='', entry=None, reply_text=''):
    snapshot = _review_snapshot(rating, platform=platform, entry=entry, reply_text=reply_text)
    result = {
        'email_sent': False,
        'notification_sent': False,
        'errors': [],
    }

    try:
        email_sent, email_error = send_review_reply_email(snapshot)
        result['email_sent'] = email_sent
        if email_error:
            result['errors'].append(email_error)
    except Exception as exc:
        logger.exception('Could not send review reply email for rating %s', rating.pk)
        result['errors'].append(f'Email failed: {exc}')

    try:
        notification_sent, notification_error = send_review_reply_notification(snapshot)
        result['notification_sent'] = notification_sent
        if notification_error:
            result['errors'].append(notification_error)
    except Exception as exc:
        logger.exception('Could not send in-app review reply for rating %s', rating.pk)
        result['errors'].append(f'App notification failed: {exc}')

    return result
