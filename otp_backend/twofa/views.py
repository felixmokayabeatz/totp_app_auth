from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.core.mail import EmailMultiAlternatives
from django.conf import settings
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.utils import timezone
from rest_framework_simplejwt.tokens import RefreshToken
from api.backup_codes import (
    decrypt_backup_codes,
    encrypt_backup_codes,
    normalize_backup_code,
    normalize_backup_code_entries,
    remaining_backup_codes,
)
from api.models import BackupCodeSet
from .models import EmailVerification
from .email_templates import get_2fa_email_template, get_password_changed_email_template, get_password_reset_email_template
import logging
import traceback
import sys
from django.conf import settings as django_settings

logger = logging.getLogger(__name__)


def debug_print(*args, **kwargs):
    """Conditional print only when DEBUG=True"""
    if django_settings.DEBUG:
        print(*args, **kwargs)


def _consume_recovery_code(user: User, raw_code: str):
    code_set = BackupCodeSet.objects.filter(user=user).first()
    if code_set is None or not code_set.encrypted_codes:
        return False, 'No recovery codes available for this account.'

    entries = normalize_backup_code_entries(
        decrypt_backup_codes(code_set.encrypted_codes)
    )
    normalized_code = normalize_backup_code(raw_code)

    matched_entry = None
    for entry in entries:
        if entry.get('code') == normalized_code:
            matched_entry = entry
            break

    if matched_entry is None:
        return False, 'Invalid recovery code.'

    if matched_entry.get('used_at'):
        return False, 'This recovery code has already been used.'

    used_at = timezone.now()
    matched_entry['used_at'] = used_at.isoformat()
    code_set.encrypted_codes = encrypt_backup_codes(entries)
    code_set.last_used_at = used_at
    code_set.save(update_fields=['encrypted_codes', 'last_used_at', 'updated_at'])

    return True, {
        'remaining_codes': remaining_backup_codes(entries),
        'last_used_at': used_at.isoformat(),
    }


@api_view(['POST'])
@permission_classes([AllowAny])
def send_2fa_code(request):
    start_time = __import__('time').time()
    username = (request.data.get('username') or '').strip()
    password = request.data.get('password')
    
    # Debug print
    debug_print(f"\n{'='*60}")
    debug_print(f"[2FA] send_2fa_code called")
    debug_print(f"[2FA] Username: {username}")
    debug_print(f"[2FA] Password provided: {'Yes' if password else 'No'}")
    debug_print(f"[2FA] Request IP: {request.META.get('REMOTE_ADDR')}")
    debug_print(f"[2FA] User Agent: {request.META.get('HTTP_USER_AGENT', 'unknown')[:50]}")
    debug_print(f"{'='*60}\n")
    
    # Log to file
    logger.info(f"2FA code request - Username: {username}, IP: {request.META.get('REMOTE_ADDR')}")
    
    if not username or not password:
        debug_print(f"[2FA] ERROR: Missing username or password")
        logger.warning(f"2FA request missing username or password - Username: {username}")
        return Response({'success': False, 'error': 'Username and password required'}, status=400)
    
    try:
        # Try to find user
        debug_print(f"[2FA] Looking up user: {username}")
        try:
            user_obj = User.objects.get(username__iexact=username)
            auth_username = user_obj.username
            debug_print(f"[2FA] User found: {auth_username} (ID: {user_obj.id})")
        except User.DoesNotExist:
            debug_print(f"[2FA] User not found: {username}")
            auth_username = username

        # Authenticate
        debug_print(f"[2FA] Authenticating user: {auth_username}")
        user = authenticate(username=auth_username, password=password)
        
        if not user:
            debug_print(f"[2FA] Authentication FAILED for user: {auth_username}")
            logger.warning(f"2FA authentication failed - Username: {auth_username}, IP: {request.META.get('REMOTE_ADDR')}")
            return Response({'success': False, 'error': 'Invalid username or password'}, status=401)
        
        debug_print(f"[2FA] Authentication SUCCESS for user: {user.username} (ID: {user.id})")
        
        if not user.email:
            debug_print(f"[2FA] ERROR: User {user.username} has no email address")
            logger.error("2FA code cannot be sent because the account has no email address.")
            return Response({'success': False, 'error': 'No email associated with account'}, status=400)
        
        debug_print(f"[2FA] User email: {user.email}")
        
        # Delete old codes
        debug_print(f"[2FA] Deleting old unused codes for user: {user.username}")
        deleted_count = EmailVerification.objects.filter(user=user, is_used=False).delete()[0]
        debug_print(f"[2FA] Deleted {deleted_count} old codes")
        
        # Create new verification code
        debug_print(f"[2FA] Creating new verification code")
        verification = EmailVerification.objects.create(user=user)
        debug_print(f"[2FA] Created code: {verification.code} for user: {user.username}")
        
        # Prepare email
        debug_print(f"[2FA] Preparing email to: {user.email}")
        html_content = get_2fa_email_template(user.username, verification.code)
        text_content = f"Your 2FA verification code is: {verification.code}\n\nThis code expires in 10 minutes."
        
        email = EmailMultiAlternatives(
            subject='Your 2FA Verification Code - OTP Authenticator',
            body=text_content,
            from_email=settings.EMAIL_HOST_USER,
            to=[user.email],
        )
        email.attach_alternative(html_content, "text/html")
        
        # Send email
        debug_print(f"[2FA] Sending email...")
        email.send()
        
        elapsed_time = __import__('time').time() - start_time
        debug_print(f"[2FA] Email sent successfully in {elapsed_time:.2f} seconds")
        
        logger.info(f'2FA code sent successfully - User: {user.username}, Email: {user.email}, Code: {verification.code}')
        
        return Response({
            'success': True,
            'message': f'Verification code sent to {user.email}',
        })
        
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"\n{'='*60}")
        debug_print(f"[2FA] EXCEPTION OCCURRED!")
        debug_print(f"[2FA] Error type: {type(e).__name__}")
        debug_print(f"[2FA] Error message: {str(e)}")
        debug_print(f"[2FA] Full traceback:")
        debug_print(error_details)
        debug_print(f"{'='*60}\n")
        
        logger.error("2FA code sending failed.\n%s", error_details)
        return Response({'success': False, 'error': str(e)}, status=500)
    

@api_view(['POST'])
@permission_classes([AllowAny])
def verify_2fa_code(request):
    start_time = __import__('time').time()
    username = (request.data.get('username') or '').strip()
    code = (request.data.get('code') or '').strip()
    
    debug_print(f"\n{'='*60}")
    debug_print(f"[2FA] verify_2fa_code called")
    debug_print(f"[2FA] Username: {username}")
    debug_print(f"[2FA] Code: {code}")
    debug_print(f"[2FA] Request IP: {request.META.get('REMOTE_ADDR')}")
    debug_print(f"{'='*60}\n")
    
    logger.info(f"2FA verification attempt - Username: {username}, IP: {request.META.get('REMOTE_ADDR')}")
    
    if not username or not code:
        debug_print(f"[2FA] ERROR: Missing username or code")
        logger.warning(f"2FA verification missing username or code")
        return Response({'success': False, 'error': 'Username and code required'}, status=400)
    
    try:
        debug_print(f"[2FA] Looking up user: {username}")
        user = User.objects.get(username__iexact=username)
        debug_print(f"[2FA] User found: {user.username} (ID: {user.id})")
        
        # Get the LATEST unused code
        debug_print(f"[2FA] Fetching latest unused code for user")
        verification = EmailVerification.objects.filter(
            user=user, 
            is_used=False
        ).order_by('-created_at').first()
        
        if not verification:
            debug_print(f"[2FA] No valid unused code found for user: {user.username}")
            logger.warning(f"No valid code found for user: {user.username}")
            return Response({'success': False, 'error': 'No valid code found. Request a new one.'}, status=400)
        
        debug_print(f"[2FA] Found code - ID: {verification.id}, Code: {verification.code}, Created: {verification.created_at}")
        
        if verification.code != code:
            debug_print(f"[2FA] Code mismatch - Expected: {verification.code}, Got: {code}")
            logger.warning(f"Invalid code attempt for user: {user.username} - Expected: {verification.code}, Got: {code}")
            return Response({'success': False, 'error': 'Invalid code'}, status=400)
        
        debug_print(f"[2FA] Code matches, checking validity...")
        
        if verification.is_valid():
            debug_print(f"[2FA] Code is valid, marking as used")
            verification.is_used = True
            verification.save()
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[2FA] Code verified successfully in {elapsed_time:.2f} seconds")
            
            logger.info(f'2FA code verified successfully for user: {user.username}')
            return Response({'success': True, 'message': 'Code verified'})
        else:
            debug_print(f"[2FA] Code expired - Created: {verification.created_at}, Now: {__import__('django.utils.timezone').now()}")
            logger.warning(f'Code expired for user: {user.username}')
            return Response({'success': False, 'error': 'Code expired (10 minute limit)'}, status=400)
            
    except User.DoesNotExist:
        debug_print(f"[2FA] User not found: {username}")
        logger.warning(f"User not found for verification: {username}")
        return Response({'success': False, 'error': 'User not found'}, status=400)
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"\n{'='*60}")
        debug_print(f"[2FA] EXCEPTION in verify_2fa_code!")
        debug_print(f"[2FA] Error: {str(e)}")
        debug_print(f"[2FA] Traceback:\n{error_details}")
        debug_print(f"{'='*60}\n")
        
        logger.error("2FA verification failed.\n%s", error_details)
        return Response({'success': False, 'error': str(e)}, status=500)
    

@api_view(['POST'])
@permission_classes([AllowAny])
def send_password_reset_code(request):
    start_time = __import__('time').time()
    email = (request.data.get('email') or '').strip()
    
    debug_print(f"\n{'='*60}")
    debug_print(f"[PASSWORD RESET] send_password_reset_code called")
    debug_print(f"[PASSWORD RESET] Email: {email}")
    debug_print(f"[PASSWORD RESET] Request IP: {request.META.get('REMOTE_ADDR')}")
    debug_print(f"{'='*60}\n")
    
    logger.info(f"Password reset request - Email: {email}, IP: {request.META.get('REMOTE_ADDR')}")
    
    if not email:
        debug_print(f"[PASSWORD RESET] ERROR: No email provided")
        logger.warning(f"Password reset request missing email")
        return Response({'success': False, 'error': 'Email required'}, status=400)
    
    try:
        debug_print(f"[PASSWORD RESET] Looking up user by email: {email}")
        user = User.objects.get(email__iexact=email)
        debug_print(f"[PASSWORD RESET] User found: {user.username} (ID: {user.id})")
        
        # Delete old codes
        debug_print(f"[PASSWORD RESET] Deleting old unused reset codes")
        deleted_count = EmailVerification.objects.filter(user=user, is_used=False).delete()[0]
        debug_print(f"[PASSWORD RESET] Deleted {deleted_count} old codes")
        
        # Create new code
        debug_print(f"[PASSWORD RESET] Creating new reset code")
        verification = EmailVerification.objects.create(user=user)
        debug_print(f"[PASSWORD RESET] Created code: {verification.code}")
        
        # Prepare and send email
        debug_print(f"[PASSWORD RESET] Preparing reset email")
        html_content = get_password_reset_email_template(user.username, verification.code)
        text_content = f"Your password reset code is: {verification.code}\n\nThis code expires in 10 minutes."
        
        email_msg = EmailMultiAlternatives(
            subject='Password Reset Code - BeatzLock Authenticator',
            body=text_content,
            from_email=settings.EMAIL_HOST_USER,
            to=[user.email],
        )
        email_msg.attach_alternative(html_content, "text/html")
        
        debug_print(f"[PASSWORD RESET] Sending email to: {user.email}")
        email_msg.send()
        
        elapsed_time = __import__('time').time() - start_time
        debug_print(f"[PASSWORD RESET] Email sent successfully in {elapsed_time:.2f} seconds")
        
        logger.info(f'Password reset code sent - User: {user.username}, Email: {user.email}, Code: {verification.code}')
        
        return Response({
            'success': True,
            'message': f'Reset code sent to {user.email}',
        })
        
    except User.DoesNotExist:
        debug_print(f"[PASSWORD RESET] User not found with email: {email}")
        logger.warning(f"Password reset - No account found with email: {email}")
        return Response({'success': False, 'error': 'No account found with this email'}, status=404)
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"\n{'='*60}")
        debug_print(f"[PASSWORD RESET] EXCEPTION!")
        debug_print(f"[PASSWORD RESET] Error: {str(e)}")
        debug_print(f"[PASSWORD RESET] Traceback:\n{error_details}")
        debug_print(f"{'='*60}\n")
        
        logger.error("Password reset code sending failed.\n%s", error_details)
        return Response({'success': False, 'error': str(e)}, status=500)


@api_view(['POST'])
@permission_classes([AllowAny])
def reset_password(request):
    start_time = __import__('time').time()
    email = (request.data.get('email') or '').strip()
    code = (request.data.get('code') or '').strip()
    new_password = request.data.get('new_password')
    
    debug_print(f"\n{'='*60}")
    debug_print(f"[PASSWORD RESET] reset_password called")
    debug_print(f"[PASSWORD RESET] Email: {email}")
    debug_print(f"[PASSWORD RESET] Code: {code}")
    debug_print(f"[PASSWORD RESET] New password length: {len(new_password) if new_password else 0}")
    debug_print(f"[PASSWORD RESET] Request IP: {request.META.get('REMOTE_ADDR')}")
    debug_print(f"{'='*60}\n")
    
    logger.info(f"Password reset execution - Email: {email}, IP: {request.META.get('REMOTE_ADDR')}")
    
    if not email or not code or not new_password:
        debug_print(f"[PASSWORD RESET] ERROR: Missing required fields")
        logger.warning(f"Password reset missing fields - Email: {email}, Code provided: {bool(code)}, Password provided: {bool(new_password)}")
        return Response({'success': False, 'error': 'Email, code, and new password required'}, status=400)
    
    if len(new_password) < 8:
        debug_print(f"[PASSWORD RESET] ERROR: Password too short (length: {len(new_password)})")
        logger.warning(f"Password reset - Password too short: {len(new_password)} characters")
        return Response({'success': False, 'error': 'Password must be at least 8 characters'}, status=400)
    
    try:
        debug_print(f"[PASSWORD RESET] Looking up user by email: {email}")
        user = User.objects.get(email__iexact=email)
        debug_print(f"[PASSWORD RESET] User found: {user.username} (ID: {user.id})")
        
        # Get the LATEST unused reset code
        debug_print(f"[PASSWORD RESET] Fetching latest unused reset code")
        verification = EmailVerification.objects.filter(
            user=user, 
            is_used=False
        ).order_by('-created_at').first()
        
        if not verification:
            debug_print(f"[PASSWORD RESET] No valid unused code found")
            logger.warning(f"Password reset - No valid code for user: {user.username}")
            return Response({'success': False, 'error': 'No valid code found. Request a new one.'}, status=400)
        
        debug_print(f"[PASSWORD RESET] Found code - ID: {verification.id}, Code: {verification.code}, Created: {verification.created_at}")
        
        if verification.code != code:
            debug_print(f"[PASSWORD RESET] Code mismatch - Expected: {verification.code}, Got: {code}")
            logger.warning(f"Password reset - Invalid code for user: {user.username}")
            return Response({'success': False, 'error': 'Invalid code'}, status=400)
        
        debug_print(f"[PASSWORD RESET] Code matches, checking validity...")
        
        if not verification.is_valid():
            debug_print(f"[PASSWORD RESET] Code expired")
            logger.warning(f"Password reset - Expired code for user: {user.username}")
            return Response({'success': False, 'error': 'Code expired (10 minute limit)'}, status=400)
        
        # Reset password
        debug_print(f"[PASSWORD RESET] Resetting password for user: {user.username}")
        user.set_password(new_password)
        user.save()
        debug_print(f"[PASSWORD RESET] Password changed successfully")
        
        # Mark code as used
        verification.is_used = True
        verification.save()
        debug_print(f"[PASSWORD RESET] Code marked as used")
        
        # Delete any other unused codes
        deleted_count = EmailVerification.objects.filter(user=user, is_used=False).delete()[0]
        debug_print(f"[PASSWORD RESET] Deleted {deleted_count} other unused codes")
        
        # Send password changed notification
        debug_print(f"[PASSWORD RESET] Sending password changed notification to: {user.email}")
        html_content = get_password_changed_email_template(user.username)
        text_content = f"Your password has been changed successfully. If you didn't make this change, please contact support immediately."
        
        email_msg = EmailMultiAlternatives(
            subject='Password Changed Successfully - BeatzLock Authenticator',
            body=text_content,
            from_email=settings.EMAIL_HOST_USER,
            to=[user.email],
        )
        email_msg.attach_alternative(html_content, "text/html")
        email_msg.send()
        
        elapsed_time = __import__('time').time() - start_time
        debug_print(f"[PASSWORD RESET] Password reset completed successfully in {elapsed_time:.2f} seconds")
        
        logger.info(f'Password reset successful for user: {user.username}, Email: {user.email}')
        
        return Response({'success': True, 'message': 'Password reset successfully'})
        
    except User.DoesNotExist:
        debug_print(f"[PASSWORD RESET] User not found with email: {email}")
        logger.warning(f"Password reset - User not found: {email}")
        return Response({'success': False, 'error': 'User not found'}, status=404)
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"\n{'='*60}")
        debug_print(f"[PASSWORD RESET] EXCEPTION in reset_password!")
        debug_print(f"[PASSWORD RESET] Error: {str(e)}")
        debug_print(f"[PASSWORD RESET] Traceback:\n{error_details}")
        debug_print(f"{'='*60}\n")
        
        logger.error("Password reset execution failed.\n%s", error_details)
        return Response({'success': False, 'error': str(e)}, status=500)


@api_view(['POST'])
@permission_classes([AllowAny])
def verify_recovery_code_login(request):
    username = (request.data.get('username') or '').strip()
    password = request.data.get('password')
    recovery_code = (request.data.get('recovery_code') or '').strip()

    if not username or not password or not recovery_code:
        return Response(
            {'success': False, 'error': 'Username, password, and recovery code required'},
            status=400,
        )

    try:
        user_obj = User.objects.get(username__iexact=username)
        user = authenticate(username=user_obj.username, password=password)
        if not user:
            return Response({'success': False, 'error': 'Invalid username or password'}, status=401)

        consumed, result = _consume_recovery_code(user, recovery_code)
        if not consumed:
            return Response({'success': False, 'error': result}, status=400)

        return Response({
            'success': True,
            'message': 'Recovery code verified successfully.',
            'remaining_codes': result['remaining_codes'],
        })
    except User.DoesNotExist:
        return Response({'success': False, 'error': 'User not found'}, status=400)
    except Exception as e:
        error_details = traceback.format_exc()
        logger.error("Recovery code login verification failed.\n%s", error_details)
        return Response({'success': False, 'error': str(e)}, status=500)


@api_view(['POST'])
@permission_classes([AllowAny])
def check_recovery_email(request):
    email = (request.data.get('email') or '').strip()

    if not email:
        return Response({'success': False, 'error': 'Email required'}, status=400)

    exists = User.objects.filter(email__iexact=email).exists()
    if not exists:
        return Response({'success': False, 'error': 'No account found with this email'}, status=404)

    return Response({'success': True})


@api_view(['POST'])
@permission_classes([AllowAny])
def reset_password_with_recovery_code(request):
    email = (request.data.get('email') or '').strip()
    recovery_code = (request.data.get('recovery_code') or '').strip()
    new_password = request.data.get('new_password')

    if not email or not recovery_code or not new_password:
        return Response(
            {'success': False, 'error': 'Email, recovery code, and new password required'},
            status=400,
        )

    if len(new_password) < 8:
        return Response(
            {'success': False, 'error': 'Password must be at least 8 characters'},
            status=400,
        )

    try:
        user = User.objects.get(email__iexact=email)
        consumed, result = _consume_recovery_code(user, recovery_code)
        if not consumed:
            return Response({'success': False, 'error': result}, status=400)

        user.set_password(new_password)
        user.save()
        EmailVerification.objects.filter(user=user, is_used=False).delete()
        refresh = RefreshToken.for_user(user)

        if user.email:
            html_content = get_password_changed_email_template(user.username)
            text_content = (
                "Your BeatzLock recovery code was used to change your password and sign in to your account. "
                "If you didn't make this change, please reset your password immediately."
            )
            email_msg = EmailMultiAlternatives(
                subject='Recovery code used to change your password - BeatzLock Authenticator',
                body=text_content,
                from_email=settings.EMAIL_HOST_USER,
                to=[user.email],
            )
            email_msg.attach_alternative(html_content, "text/html")
            email_msg.send()

        return Response({
            'success': True,
            'message': 'Password reset successfully.',
            'remaining_codes': result['remaining_codes'],
            'user': {
                'id': user.id,
                'username': user.username,
                'email': user.email,
            },
            'access': str(refresh.access_token),
            'refresh': str(refresh),
        })
    except User.DoesNotExist:
        return Response({'success': False, 'error': 'No account found with this email'}, status=404)
    except Exception as e:
        error_details = traceback.format_exc()
        logger.error("Password reset with recovery code failed.\n%s", error_details)
        return Response({'success': False, 'error': str(e)}, status=500)
