from django.conf import settings
from django.core.mail import EmailMultiAlternatives
from django.template.loader import render_to_string
from django.utils import timezone


def _support_email():
    return getattr(settings, 'SUPPORT_EMAIL', '') or getattr(settings, 'EMAIL_HOST_USER', '') or ''


def _from_email():
    return getattr(settings, 'DEFAULT_FROM_EMAIL', '') or getattr(settings, 'EMAIL_HOST_USER', '') or None


def _base_context(
    username,
    *,
    preheader,
    title,
    subtitle,
    intro,
    code=None,
    sections=None,
    notice=None,
    follow_up=None,
):
    return {
        'preheader': preheader,
        'eyebrow': 'BeatzLock Authenticator',
        'title': title,
        'subtitle': subtitle,
        'greeting': f'Hello {username},',
        'intro': intro,
        'code': code,
        'sections': sections or [],
        'notice': notice,
        'follow_up': follow_up,
        'support_email': _support_email(),
        'current_year': timezone.now().year,
    }


def _render_html(context):
    return render_to_string('emails/beatzlock_transactional_email.html', context)


def _render_text(context):
    lines = [
        context['greeting'],
        '',
        context['intro'],
    ]

    code = context.get('code')
    if code:
        lines.extend([
            '',
            f"{code['label']}: {code['value']}",
            code['caption'],
        ])

    for section in context.get('sections') or []:
        lines.extend([
            '',
            f"{section['label']}:",
            section['body'],
        ])

    for block in (context.get('notice'), context.get('follow_up')):
        if block:
            lines.extend([
                '',
                f"{block['title']}:",
                block['body'],
            ])

    lines.extend([
        '',
        'BeatzLock Authenticator',
        'This is an automated security message, please do not reply.',
    ])
    return '\n'.join(lines)


def send_transactional_email(*, subject, recipient, text_content, html_content, fail_silently=False):
    support_email = _support_email()
    email = EmailMultiAlternatives(
        subject=subject,
        body=text_content,
        from_email=_from_email(),
        to=[recipient],
        reply_to=[support_email] if support_email else None,
        headers={
            'X-Auto-Response-Suppress': 'All',
            'Auto-Submitted': 'auto-generated',
        },
    )
    email.attach_alternative(html_content, 'text/html')
    email.send(fail_silently=fail_silently)


def _two_factor_context(username, code):
    return _base_context(
        username,
        preheader='Use this BeatzLock verification code to complete your sign-in.',
        title='Your verification code',
        subtitle='A secure code was requested for your account.',
        intro='Use the verification code below to complete your sign-in or identity check.',
        code={
            'label': 'Verification code',
            'value': code,
            'caption': 'This code expires in 10 minutes.',
        },
        notice={
            'tone': 'warning',
            'title': "Didn't request this?",
            'body': 'You can ignore this email if you did not request a sign-in or security check.',
        },
    )


def get_2fa_email_template(username, code):
    return _render_html(_two_factor_context(username, code))


def get_2fa_email_text(username, code):
    return _render_text(_two_factor_context(username, code))


def _password_reset_context(username, code):
    return _base_context(
        username,
        preheader='Use this BeatzLock password reset code before it expires.',
        title='Reset your password',
        subtitle='A password reset was requested for your account.',
        intro='Use the code below to reset your BeatzLock password in the app.',
        code={
            'label': 'Password reset code',
            'value': code,
            'caption': 'This code expires in 10 minutes.',
        },
        notice={
            'tone': 'warning',
            'title': 'Security note',
            'body': 'If you did not request a password reset, ignore this email and keep your account password private.',
        },
    )


def get_password_reset_email_template(username, code):
    return _render_html(_password_reset_context(username, code))


def get_password_reset_email_text(username, code):
    return _render_text(_password_reset_context(username, code))


def _password_changed_context(username):
    return _base_context(
        username,
        preheader='Your BeatzLock password was changed successfully.',
        title='Password changed',
        subtitle='Your account password was updated.',
        intro='Your BeatzLock password has been changed successfully.',
        sections=[
            {
                'label': 'What to do next',
                'body': 'If this was you, no further action is needed.',
            },
        ],
        notice={
            'tone': 'danger',
            'title': 'If this was not you',
            'body': 'Reset your password immediately and review your signed-in devices.',
        },
    )


def get_password_changed_email_template(username):
    return _render_html(_password_changed_context(username))


def get_password_changed_email_text(username):
    return _render_text(_password_changed_context(username))


def _recovery_password_changed_context(username):
    return _base_context(
        username,
        preheader='A BeatzLock recovery code was used to change your password.',
        title='Recovery code used',
        subtitle='Your password was changed with a recovery code.',
        intro='A BeatzLock recovery code was used to change your password and sign in to your account.',
        sections=[
            {
                'label': 'What happened',
                'body': 'Your older sign-in state may no longer be trusted if this was not you.',
            },
        ],
        notice={
            'tone': 'danger',
            'title': 'Important',
            'body': 'If you did not make this change, reset your password immediately and generate a fresh set of recovery codes.',
        },
    )


def get_recovery_code_password_changed_email_template(username):
    return _render_html(_recovery_password_changed_context(username))


def get_recovery_code_password_changed_email_text(username):
    return _render_text(_recovery_password_changed_context(username))


def _delete_otp_context(username, code):
    return _base_context(
        username,
        preheader='Use this BeatzLock code only if you want to delete all stored accounts.',
        title='Confirm account deletion',
        subtitle='This action permanently removes your saved accounts.',
        intro='You requested to permanently delete all OTP accounts from this device, your other devices, and the cloud.',
        code={
            'label': 'Deletion confirmation code',
            'value': code,
            'caption': 'This code expires in 10 minutes.',
        },
        notice={
            'tone': 'danger',
            'title': 'What will be deleted',
            'body': 'All saved OTP accounts will be removed permanently. This action cannot be undone.',
        },
        follow_up={
            'tone': 'info',
            'title': "Didn't request this?",
            'body': 'Ignore this email if you did not start this action. Nothing will be deleted unless the code is entered in the app.',
        },
    )


def get_delete_otp_email_template(username, code):
    return _render_html(_delete_otp_context(username, code))


def get_delete_otp_email_text(username, code):
    return _render_text(_delete_otp_context(username, code))


def _recovery_codes_generated_context(
    username,
    *,
    generated_at: str = '',
    device_label: str = '',
):
    device_phrase = (
        f'from your primary device {device_label}'
        if device_label
        else 'from your primary device'
    )
    time_phrase = f' at {generated_at}' if generated_at else ''
    return _base_context(
        username,
        preheader='A fresh set of BeatzLock recovery codes was generated for your account.',
        title='Recovery codes updated',
        subtitle='Your account recovery kit was refreshed.',
        intro='A brand new set of BeatzLock recovery codes was generated for your account and included in the downloaded PDF.',
        sections=[
            {
                'label': 'What changed',
                'body': 'All older recovery codes are now invalid. Only the newest PDF and the codes inside it can be used.',
            },
            {
                'label': 'Generated from',
                'body': f'{device_phrase}{time_phrase}.',
            },
        ],
        notice={
            'tone': 'warning',
            'title': 'Security tip',
            'body': 'Store the new PDF somewhere safe and private. If you did not generate these recovery codes, change your password immediately.',
        },
    )


def get_recovery_codes_generated_email_template(
    username,
    *,
    generated_at: str = '',
    device_label: str = '',
):
    return _render_html(
        _recovery_codes_generated_context(
            username,
            generated_at=generated_at,
            device_label=device_label,
        )
    )


def get_recovery_codes_generated_email_text(
    username,
    *,
    generated_at: str = '',
    device_label: str = '',
):
    return _render_text(
        _recovery_codes_generated_context(
            username,
            generated_at=generated_at,
            device_label=device_label,
        )
    )
