from rest_framework import viewsets, status
from rest_framework.decorators import (
    action,
    api_view,
    authentication_classes,
    permission_classes,
)
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.exceptions import AuthenticationFailed
from rest_framework_simplejwt.tokens import RefreshToken
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.utils.crypto import constant_time_compare
from django.utils import timezone
from django.conf import settings
from django.http import HttpResponse
from datetime import timedelta
import hashlib
import json
import random
import string
import logging
import traceback
from django.conf import settings as django_settings

from .backup_codes import (
    build_backup_codes_pdf,
    build_backup_code_entries,
    decrypt_backup_codes,
    encrypt_backup_codes,
    generate_backup_codes,
    normalize_backup_code_entries,
    remaining_backup_codes,
)
from .models import (
    AppNotification,
    BulkAccountDeleteRequest,
    DeviceSession,
    EncryptedData,
    SyncLog,
    AccountTombstone,
    DeleteOTPCode,
    BackupCodeSet,
    PasswordlessLoginRequest,
)
from .notifications import (
    build_device_label,
    create_account_added_notification,
    create_accounts_imported_notification,
    create_app_pin_changed_notification,
    create_app_review_reply_notification,
    create_bulk_delete_request_notification,
    create_daily_active_devices_notification,
    create_passwords_imported_notification,
    create_passwordless_request_notification,
    create_password_changed_notification,
    create_recovery_code_used_notification,
    create_recovery_codes_generated_notification,
    create_sign_in_notification,
)
from .device_sessions import (
    attach_session_to_refresh_token,
    ensure_primary_session,
    ensure_device_session,
    extract_request_ip,
    find_active_device_session,
    get_request_device_id,
    get_request_device_fingerprint,
    get_request_device_kind,
    get_request_device_label,
)
from .serializers import (
    AppNotificationSerializer,
    BulkAccountDeleteRequestSerializer,
    DeviceSessionSerializer,
    PasswordlessLoginRequestSerializer,
    UserSerializer,
    EncryptedDataSerializer,
    RegisterSerializer,
)
from twofa.email_templates import (
    get_delete_otp_email_template,
    get_delete_otp_email_text,
    get_recovery_codes_generated_email_template,
    get_recovery_codes_generated_email_text,
    send_transactional_email,
)
from twofa.models import EmailVerification
from twofa.views import _consume_recovery_code

# ===================
# LOGGING SETUP
# ===================
logger = logging.getLogger(__name__)


def debug_print(*args, **kwargs):
    """Conditional print only when DEBUG=True"""
    if django_settings.DEBUG:
        print(*args, **kwargs)


def get_request_pdf_theme(request) -> str:
    candidates = []
    if hasattr(request, 'query_params'):
        candidates.append(request.query_params.get('pdf_theme'))
    candidates.append(request.headers.get('X-PDF-Theme'))

    for value in candidates:
        normalized = str(value or '').strip().lower()
        if normalized in {'light', 'dark'}:
            return normalized
    return 'light'


def get_current_active_device_session(request):
    auth = getattr(request, 'auth', None)
    session_id = auth.get('session_id') if hasattr(auth, 'get') else None
    device_id = get_request_device_id(request)
    device_fingerprint = get_request_device_fingerprint(request)

    request_identity_session = None
    if device_id or device_fingerprint:
        request_identity_session = find_active_device_session(
            request.user,
            device_id=device_id,
            device_fingerprint=device_fingerprint,
        )

    if session_id:
        session = DeviceSession.objects.filter(
            id=session_id,
            user=request.user,
            is_active=True,
            revoked_at__isnull=True,
        ).first()
        if (
            request_identity_session is not None
            and str(request_identity_session.id) != str(session_id)
        ):
            return request_identity_session
        if session is not None:
            return session

    return request_identity_session


def _format_passwordless_code(raw_code: str) -> str:
    cleaned = ''.join(ch for ch in raw_code if ch.isdigit())
    if len(cleaned) >= 3:
        return cleaned[:3]
    return raw_code


def _generate_passwordless_code() -> str:
    return _format_passwordless_code(''.join(random.choices(string.digits, k=3)))


def _generate_passwordless_seed() -> str:
    alphabet = string.ascii_uppercase + string.digits
    return ''.join(random.choices(alphabet, k=6))


def _build_passwordless_choices(request_obj: PasswordlessLoginRequest) -> list[str]:
    correct = request_obj.get_verification_code()
    seen = {correct}
    decoys = []
    counter = 0

    while len(decoys) < 2:
        digest = hashlib.sha256(
            f'{request_obj.id}|{correct}|{counter}'.encode('utf-8')
        ).hexdigest()
        candidate = str(int(digest[:8], 16) % 1000).zfill(3)
        counter += 1
        if candidate in seen:
            continue
        seen.add(candidate)
        decoys.append(candidate)

    choices = [correct, *decoys]
    shuffle_seed = int(
        hashlib.sha256(f'shuffle|{request_obj.id}'.encode('utf-8')).hexdigest()[:8],
        16,
    )
    random.Random(shuffle_seed).shuffle(choices)
    return choices


def _expire_stale_passwordless_requests(user: User | None = None):
    queryset = PasswordlessLoginRequest.objects.filter(
        status=PasswordlessLoginRequest.STATUS_PENDING,
        expires_at__lt=timezone.now(),
    )
    if user is not None:
        queryset = queryset.filter(user=user)
    queryset.update(
        status=PasswordlessLoginRequest.STATUS_EXPIRED,
        updated_at=timezone.now(),
    )


def _expire_stale_bulk_delete_requests(user: User | None = None):
    queryset = BulkAccountDeleteRequest.objects.filter(
        status=BulkAccountDeleteRequest.STATUS_PENDING,
        expires_at__lt=timezone.now(),
    )
    if user is not None:
        queryset = queryset.filter(user=user)
    queryset.update(
        status=BulkAccountDeleteRequest.STATUS_EXPIRED,
        updated_at=timezone.now(),
    )


def _apply_account_tombstones(user: User, account_ids: list[str]) -> int:
    normalized_ids = []
    seen = set()
    for account_id in account_ids:
        raw_id = str(account_id or '').strip()
        if not raw_id or raw_id in seen:
            continue
        seen.add(raw_id)
        normalized_ids.append(raw_id)

    if not normalized_ids:
        return 0

    AccountTombstone.objects.bulk_create(
        [
            AccountTombstone(user=user, account_id=account_id)
            for account_id in normalized_ids
        ],
        ignore_conflicts=True,
    )

    encrypted_data = EncryptedData.objects.filter(
        user=user,
        data_type='otp_accounts',
    ).first()
    if encrypted_data is not None:
        try:
            deleted_accounts = json.loads(encrypted_data.deleted_accounts) if encrypted_data.deleted_accounts else []
        except Exception:
            deleted_accounts = []
        deleted_set = {str(item) for item in deleted_accounts}
        changed = False
        for account_id in normalized_ids:
            if account_id in deleted_set:
                continue
            deleted_accounts.append(account_id)
            deleted_set.add(account_id)
            changed = True
        if changed:
            encrypted_data.deleted_accounts = json.dumps(deleted_accounts)
            encrypted_data.save(update_fields=['deleted_accounts', 'updated_at'])

    return len(normalized_ids)


# ===================
# AUTH VIEWSET
# ===================
class AuthViewSet(viewsets.GenericViewSet):
    permission_classes = [AllowAny]
    serializer_class = RegisterSerializer
    
    @action(detail=False, methods=['post'])
    def register(self, request):
        start_time = __import__('time').time()
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[AUTH] Register called")
        debug_print(f"[AUTH] Username: {request.data.get('username')}")
        debug_print(f"[AUTH] Email: {request.data.get('email')}")
        debug_print(f"[AUTH] Request IP: {request.META.get('REMOTE_ADDR')}")
        debug_print(f"[AUTH] User Agent: {request.META.get('HTTP_USER_AGENT', 'unknown')[:50]}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Registration attempt - IP: {request.META.get('REMOTE_ADDR')}, Username: {request.data.get('username')}")
        
        serializer = RegisterSerializer(data=request.data)
        if serializer.is_valid():
            debug_print(f"[AUTH] Registration data validation PASSED")
            
            try:
                user = serializer.save()
                debug_print(f"[AUTH] User created successfully - ID: {user.id}, Username: {user.username}, Email: {user.email}")
                
                refresh = RefreshToken.for_user(user)
                attach_session_to_refresh_token(user, request, refresh)
                
                elapsed_time = __import__('time').time() - start_time
                debug_print(f"[AUTH] Registration completed in {elapsed_time:.2f} seconds")
                
                logger.info(f"User registered successfully - Username: {user.username}, Email: {user.email}, ID: {user.id}")
                
                return Response({
                    'user': UserSerializer(user).data,
                    'access': str(refresh.access_token),
                    'refresh': str(refresh),
                })
                
            except Exception as e:
                error_details = traceback.format_exc()
                debug_print(f"[AUTH] ERROR saving user: {str(e)}")
                debug_print(f"[AUTH] Traceback:\n{error_details}")
                logger.error("Registration save failed.\n%s", error_details)
                return Response({'error': 'Failed to create user'}, status=500)
        
        debug_print(f"[AUTH] Registration validation FAILED: {serializer.errors}")
        logger.warning(f"Registration failed - Username: {request.data.get('username')}, Errors: {serializer.errors}")
        return Response(serializer.errors, status=400)
    
    @action(detail=False, methods=['post'])
    def login(self, request):
        start_time = __import__('time').time()
        username = (request.data.get('username') or '').strip()
        password = request.data.get('password')
        device_label = build_device_label(
            request.data.get('device_label'),
            request.META.get('HTTP_USER_AGENT'),
        )
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[AUTH] Login called")
        debug_print(f"[AUTH] Username: {username}")
        debug_print(f"[AUTH] Password provided: {'Yes' if password else 'No'}")
        debug_print(f"[AUTH] Request IP: {request.META.get('REMOTE_ADDR')}")
        debug_print(f"[AUTH] User Agent: {request.META.get('HTTP_USER_AGENT', 'unknown')[:50]}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Login attempt - Username: {username}, IP: {request.META.get('REMOTE_ADDR')}")
        
        if not username or not password:
            debug_print(f"[AUTH] ERROR: Missing username or password")
            logger.warning(f"Login missing credentials - Username: {username}")
            return Response({'error': 'Username and password required'}, status=400)
        
        try:
            # Try to find user for case-insensitive lookup
            debug_print(f"[AUTH] Looking up user: {username}")
            try:
                user_obj = User.objects.get(username__iexact=username)
                auth_username = user_obj.username
                debug_print(f"[AUTH] User found - ID: {user_obj.id}, Username: {auth_username}")
            except User.DoesNotExist:
                debug_print(f"[AUTH] User not found by username, will try direct authentication")
                auth_username = username
            
            debug_print(f"[AUTH] Authenticating with username: {auth_username}")
            user = authenticate(username=auth_username, password=password)
            
            if user:
                debug_print(f"[AUTH] Authentication SUCCESS - User ID: {user.id}, Username: {user.username}")
                
                refresh = RefreshToken.for_user(user)
                session = attach_session_to_refresh_token(user, request, refresh)
                create_sign_in_notification(user, session.device_label)
                
                elapsed_time = __import__('time').time() - start_time
                debug_print(f"[AUTH] Login completed in {elapsed_time:.2f} seconds")
                
                logger.info(f"User logged in successfully - Username: {user.username}, ID: {user.id}, IP: {request.META.get('REMOTE_ADDR')}")
                
                return Response({
                    'user': UserSerializer(user).data,
                    'access': str(refresh.access_token),
                    'refresh': str(refresh),
                })
            
            debug_print(f"[AUTH] Authentication FAILED for user: {username}")
            logger.warning(f"Failed login attempt - Username: {username}, IP: {request.META.get('REMOTE_ADDR')}")
            return Response({'error': 'Invalid credentials'}, status=401)
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[AUTH] ERROR during login: {str(e)}")
            debug_print(f"[AUTH] Traceback:\n{error_details}")
            logger.error("Login processing failed.\n%s", error_details)
            return Response({'error': 'Login failed'}, status=500)

    @action(detail=False, methods=['post'], url_path='passwordless-start')
    def passwordless_start(self, request):
        username = (request.data.get('username') or '').strip()
        password = request.data.get('password') or ''
        device_id = get_request_device_id(request)
        device_label = get_request_device_label(request)
        device_kind = get_request_device_kind(request)

        if not username:
            return Response({'error': 'Username is required.'}, status=400)

        try:
            user = User.objects.get(username__iexact=username)
        except User.DoesNotExist:
            return Response({'error': 'No account was found for that username.'}, status=404)

        if password:
            authenticated_user = authenticate(username=user.username, password=password)
            if not authenticated_user:
                return Response(
                    {
                        'error': 'Invalid username or password.',
                        'fallback_to_password': True,
                    },
                    status=403,
                )
            user = authenticated_user

        _expire_stale_passwordless_requests(user)
        primary_session = ensure_primary_session(user)
        if primary_session is None or not primary_session.is_active:
            return Response(
                {
                    'error': 'Passwordless sign-in is not available for this account yet. Use your normal password sign-in on this device.',
                    'fallback_to_password': True,
                },
                status=409,
            )

        if primary_session.device_kind != DeviceSession.DEVICE_KIND_MOBILE:
            return Response(
                {
                    'error': 'Passwordless sign-in needs a phone set as the active primary device. Use your normal password sign-in or move primary to a phone first.',
                    'fallback_to_password': True,
                    'primary_device_label': primary_session.device_label,
                },
                status=409,
            )

        PasswordlessLoginRequest.objects.filter(
            user=user,
            requester_device_id=device_id,
            status=PasswordlessLoginRequest.STATUS_PENDING,
        ).update(
            status=PasswordlessLoginRequest.STATUS_EXPIRED,
            updated_at=timezone.now(),
        )

        seed = _generate_passwordless_seed()
        request_obj = PasswordlessLoginRequest(
            user=user,
            requester_device_id=device_id,
            requester_device_label=device_label,
            requester_device_kind=device_kind,
            expires_at=timezone.now() + timedelta(minutes=3),
        )
        request_obj.set_verification_code(seed)
        request_obj.save()
        verification_code = request_obj.get_verification_code()
        create_passwordless_request_notification(
            user,
            requester_device_label=request_obj.requester_device_label,
        )

        return Response(
            {
                'success': True,
                'request_id': str(request_obj.id),
                'verification_code': verification_code,
                'code_expires_at': request_obj.code_expires_at().isoformat(),
                'expires_at': request_obj.expires_at.isoformat(),
                'primary_device_label': primary_session.device_label,
                'message': 'Approve this sign-in from your primary phone.',
            },
            status=201,
        )

    @action(detail=False, methods=['post'], url_path='passwordless-poll')
    def passwordless_poll(self, request):
        request_id = (request.data.get('request_id') or '').strip()
        device_id = get_request_device_id(request)

        if not request_id:
            return Response({'error': 'request_id is required.'}, status=400)

        try:
            request_obj = PasswordlessLoginRequest.objects.select_related('user').get(id=request_id)
        except PasswordlessLoginRequest.DoesNotExist:
            return Response({'error': 'Passwordless sign-in request not found.'}, status=404)

        _expire_stale_passwordless_requests(request_obj.user)
        request_obj.refresh_from_db()

        if request_obj.requester_device_id and device_id and request_obj.requester_device_id != device_id:
            return Response({'error': 'This sign-in request belongs to a different device.'}, status=403)

        if request_obj.status == PasswordlessLoginRequest.STATUS_PENDING:
            return Response({
                'success': True,
                'status': 'pending',
                'verification_code': request_obj.get_verification_code(),
                'code_expires_at': request_obj.code_expires_at().isoformat(),
            })
        if request_obj.status == PasswordlessLoginRequest.STATUS_DENIED:
            return Response({'success': False, 'status': 'denied', 'error': 'The sign-in request was denied on your primary phone.'}, status=403)
        if request_obj.status == PasswordlessLoginRequest.STATUS_EXPIRED:
            return Response({'success': False, 'status': 'expired', 'error': 'The sign-in request expired. Start again from the login screen.'}, status=410)
        if request_obj.status == PasswordlessLoginRequest.STATUS_COMPLETED:
            return Response({'success': False, 'status': 'completed', 'error': 'This sign-in request was already used.'}, status=409)
        if request_obj.status != PasswordlessLoginRequest.STATUS_APPROVED:
            return Response({'success': False, 'status': request_obj.status}, status=409)

        refresh = RefreshToken.for_user(request_obj.user)
        session = attach_session_to_refresh_token(request_obj.user, request, refresh)
        create_sign_in_notification(request_obj.user, session.device_label)
        request_obj.status = PasswordlessLoginRequest.STATUS_COMPLETED
        request_obj.completed_at = timezone.now()
        request_obj.save(update_fields=['status', 'completed_at', 'updated_at'])

        return Response(
            {
                'success': True,
                'status': 'approved',
                'message': 'Passwordless sign-in approved.',
                'requires_password_for_sync': True,
                'sync_unlock_message': 'To unlock encrypted vault sync on this new device, sign in once with your account password here later.',
                'user': UserSerializer(request_obj.user).data,
                'access': str(refresh.access_token),
                'refresh': str(refresh),
            }
        )

    @action(detail=False, methods=['post'], url_path='recover-primary-device')
    def recover_primary_device(self, request):
        username = (request.data.get('username') or '').strip()
        password = request.data.get('password') or ''
        email_code = (request.data.get('email_code') or '').strip()
        recovery_code = (request.data.get('recovery_code') or '').strip()

        if not username or not password or not email_code or not recovery_code:
            return Response(
                {'error': 'Username, password, email code, and recovery code are required.'},
                status=400,
            )

        try:
            user_obj = User.objects.get(username__iexact=username)
        except User.DoesNotExist:
            return Response({'error': 'No account was found for that username.'}, status=404)

        user = authenticate(username=user_obj.username, password=password)
        if not user:
            return Response({'error': 'Account password is incorrect.'}, status=403)

        verification = EmailVerification.objects.filter(
            user=user,
            code=email_code,
            is_used=False,
        ).order_by('-created_at').first()
        if verification is None or not verification.is_valid():
            return Response({'error': 'The email verification code is invalid or expired.'}, status=400)

        session = ensure_device_session(
            user,
            device_id=get_request_device_id(request),
            device_fingerprint=get_request_device_fingerprint(request),
            device_label=get_request_device_label(request),
            device_kind=get_request_device_kind(request),
            user_agent=request.META.get('HTTP_USER_AGENT', ''),
            ip_address=extract_request_ip(request),
        )

        if session.device_kind != DeviceSession.DEVICE_KIND_MOBILE:
            return Response(
                {
                    'error': 'Primary-device recovery must finish on a phone so your primary device stays mobile.',
                },
                status=400,
            )

        consumed, result = _consume_recovery_code(user, recovery_code)
        if not consumed:
            return Response({'error': result}, status=400)

        verification.is_used = True
        verification.save(update_fields=['is_used'])

        DeviceSession.objects.filter(
            user=user,
            is_active=True,
            revoked_at__isnull=True,
            is_primary=True,
        ).exclude(id=session.id).update(
            is_primary=False,
            updated_at=timezone.now(),
        )
        if not session.is_primary:
            session.is_primary = True
            session.save(update_fields=['is_primary', 'updated_at'])

        refresh = RefreshToken.for_user(user)
        refresh['session_id'] = str(session.id)
        create_recovery_code_used_notification(
            user,
            purpose='recover your primary device',
            device_label=session.device_label,
        )

        return Response(
            {
                'success': True,
                'message': 'This phone is now your primary device.',
                'remaining_codes': result['remaining_codes'],
                'user': UserSerializer(user).data,
                'access': str(refresh.access_token),
                'refresh': str(refresh),
            }
        )
    
    @action(detail=False, methods=['post'], permission_classes=[IsAuthenticated])
    def change_password(self, request):
        start_time = __import__('time').time()
        user = request.user
        current_password = request.data.get('current_password')
        new_password = request.data.get('new_password')
        device_label = build_device_label(
            request.data.get('device_label'),
            request.META.get('HTTP_USER_AGENT'),
        )
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[AUTH] change_password called")
        debug_print(f"[AUTH] User: {user.username} (ID: {user.id})")
        debug_print(f"[AUTH] Current password provided: {'Yes' if current_password else 'No'}")
        debug_print(f"[AUTH] New password length: {len(new_password) if new_password else 0}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Password change attempt - User: {user.username}, IP: {request.META.get('REMOTE_ADDR')}")
        
        if not current_password or not new_password:
            debug_print(f"[AUTH] ERROR: Missing current or new password")
            logger.warning(f"Password change missing fields - User: {user.username}")
            return Response({'error': 'Current password and new password are required'}, status=400)
        
        if not user.check_password(current_password):
            debug_print(f"[AUTH] ERROR: Current password is incorrect")
            logger.warning(f"Password change - Incorrect current password for user: {user.username}")
            return Response({'error': 'Current password is incorrect'}, status=400)
        
        if len(new_password) < 8:
            debug_print(f"[AUTH] ERROR: New password too short (length: {len(new_password)})")
            logger.warning(f"Password change - New password too short for user: {user.username}")
            return Response({'error': 'Password must be at least 8 characters'}, status=400)
        
        try:
            user.set_password(new_password)
            user.save()
            create_password_changed_notification(
                user,
                source='account settings',
                device_label=device_label,
            )
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[AUTH] Password changed successfully in {elapsed_time:.2f} seconds")
            
            logger.info(f"Password changed successfully - User: {user.username}")
            
            return Response({'success': 'Password changed successfully'})
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[AUTH] ERROR changing password: {str(e)}")
            debug_print(f"[AUTH] Traceback:\n{error_details}")
            logger.error("Password change failed.\n%s", error_details)
            return Response({'error': 'Failed to change password'}, status=500)


# ===================
# SYNC VIEWSET
# ===================
class SyncViewSet(viewsets.GenericViewSet):
    permission_classes = [IsAuthenticated]
    serializer_class = EncryptedDataSerializer
    
    @action(detail=False, methods=['post'])
    def sync(self, request):
        start_time = __import__('time').time()
        user = request.user
        data_type = request.data.get('data_type')
        encrypted_content = request.data.get('encrypted_content')
        version = request.data.get('version', 1)
        device_id = request.data.get('device_id', 'unknown')
        deleted_accounts = request.data.get('deleted_accounts', '[]')
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[SYNC] Upload sync called")
        debug_print(f"[SYNC] User: {user.username} (ID: {user.id})")
        debug_print(f"[SYNC] Data type: {data_type}")
        debug_print(f"[SYNC] Version: {version}")
        debug_print(f"[SYNC] Device ID: {device_id}")
        debug_print(f"[SYNC] Content length: {len(encrypted_content) if encrypted_content else 0}")
        debug_print(f"[SYNC] Deleted accounts length: {len(deleted_accounts)}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Sync upload request - User: {user.username}, Type: {data_type}, Device: {device_id}, Version: {version}")
        
        if not data_type:
            debug_print(f"[SYNC] ERROR: Missing data_type")
            logger.warning(f"Sync upload missing data_type - User: {user.username}")
            return Response({'error': 'data_type is required'}, status=400)
        
        try:
            # Create or update encrypted data
            obj, created = EncryptedData.objects.update_or_create(
                user=request.user,
                data_type=data_type,
                defaults={
                    'encrypted_content': encrypted_content,
                    'version': version,
                    'synced_at': timezone.now(),
                    'deleted_accounts': deleted_accounts,
                }
            )
            
            debug_print(f"[SYNC] EncryptedData record {'created' if created else 'updated'} - ID: {obj.id}, Version: {obj.version}")
            
            # Update sync log
            sync_log, created_log = SyncLog.objects.update_or_create(
                user=request.user,
                defaults={
                    'device_id': device_id,
                    'sync_type': 'upload',
                    'status': 'success',
                    'error_message': None,
                    'timestamp': timezone.now(),
                }
            )
            
            old_total = sync_log.total_syncs
            sync_log.total_syncs = sync_log.total_syncs + 1
            sync_log.save(update_fields=['total_syncs'])
            
            debug_print(f"[SYNC] Sync log {'created' if created_log else 'updated'} - Total syncs: {old_total} -> {sync_log.total_syncs}")
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[SYNC] Upload sync completed in {elapsed_time:.2f} seconds")
            
            logger.info(f"Sync upload successful - User: {user.username}, Type: {data_type}, Created: {created}, Total syncs: {sync_log.total_syncs}")
            
            return Response({
                'status': 'synced', 
                'version': obj.version,
                'synced_at': obj.synced_at.isoformat() if obj.synced_at else None,
                'deleted_accounts': obj.deleted_accounts,
            })
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[SYNC] ERROR during upload sync: {str(e)}")
            debug_print(f"[SYNC] Traceback:\n{error_details}")
            
            # Log error in sync log
            try:
                sync_log, _ = SyncLog.objects.update_or_create(
                    user=request.user,
                    defaults={
                        'device_id': device_id,
                        'sync_type': 'upload',
                        'status': 'error',
                        'error_message': str(e)[:500],
                        'timestamp': timezone.now(),
                    }
                )
                sync_log.total_syncs = sync_log.total_syncs + 1
                sync_log.save(update_fields=['total_syncs'])
            except:
                pass
            
            logger.error("Sync upload failed.\n%s", error_details)
            return Response({'error': 'Sync failed', 'details': str(e) if django_settings.DEBUG else 'Internal error'}, status=500)
    
    @action(detail=False, methods=['get'], url_path='get-data')
    def get_data(self, request):
        start_time = __import__('time').time()
        user = request.user
        data_type = request.query_params.get('data_type')
        device_id = request.query_params.get('device_id', 'unknown')
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[SYNC] Download data called")
        debug_print(f"[SYNC] User: {user.username} (ID: {user.id})")
        debug_print(f"[SYNC] Data type: {data_type}")
        debug_print(f"[SYNC] Device ID: {device_id}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Sync download request - User: {user.username}, Type: {data_type}, Device: {device_id}")
        
        if not data_type:
            debug_print(f"[SYNC] ERROR: Missing data_type")
            logger.warning(f"Sync download missing data_type - User: {user.username}")
            return Response({'error': 'data_type is required'}, status=400)
        
        try:
            data = EncryptedData.objects.get(user=request.user, data_type=data_type)
            
            debug_print(f"[SYNC] Data found - ID: {data.id}, Version: {data.version}")
            debug_print(f"[SYNC] Content length: {len(data.encrypted_content) if data.encrypted_content else 0}")
            debug_print(f"[SYNC] Last synced: {data.synced_at}")
            
            # Update sync log
            sync_log, created_log = SyncLog.objects.update_or_create(
                user=request.user,
                defaults={
                    'device_id': device_id,
                    'sync_type': 'download',
                    'status': 'success',
                    'error_message': None,
                    'timestamp': timezone.now(),
                }
            )
            
            old_total = sync_log.total_syncs
            sync_log.total_syncs = sync_log.total_syncs + 1
            sync_log.save(update_fields=['total_syncs'])
            
            debug_print(f"[SYNC] Sync log updated - Total syncs: {old_total} -> {sync_log.total_syncs}")
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[SYNC] Download completed in {elapsed_time:.2f} seconds")
            
            logger.info(f"Sync download successful - User: {user.username}, Type: {data_type}, Version: {data.version}")
            
            return Response({
                'encrypted_content': data.encrypted_content,
                'version': data.version,
                'updated_at': data.updated_at,
                'synced_at': data.synced_at.isoformat() if data.synced_at else None,
                'deleted_accounts': data.deleted_accounts if hasattr(data, 'deleted_accounts') else '[]',
            })
            
        except EncryptedData.DoesNotExist:
            debug_print(f"[SYNC] No data found for type: {data_type}")
            logger.info(f"No data found for user {user.username}, type: {data_type}")
            return Response({'status': 'no_data'}, status=404)
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[SYNC] ERROR during download: {str(e)}")
            debug_print(f"[SYNC] Traceback:\n{error_details}")
            
            logger.error("Sync download failed.\n%s", error_details)
            return Response({'error': 'Failed to retrieve data'}, status=500)
    
    @action(detail=False, methods=['get'], url_path='tombstones')
    def tombstones(self, request):
        start_time = __import__('time').time()
        user = request.user
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[SYNC] Get tombstones called")
        debug_print(f"[SYNC] User: {user.username} (ID: {user.id})")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Get tombstones request - User: {user.username}")
        
        try:
            ids = list(
                AccountTombstone.objects
                .filter(user=request.user)
                .values_list('account_id', flat=True)
            )
            
            debug_print(f"[SYNC] Found {len(ids)} tombstoned accounts")
            if ids and django_settings.DEBUG:
                debug_print(f"[SYNC] Tombstoned IDs: {ids[:10]}{'...' if len(ids) > 10 else ''}")
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[SYNC] Tombstones retrieved in {elapsed_time:.2f} seconds")
            
            logger.info(f"Tombstones retrieved - User: {user.username}, Count: {len(ids)}")
            
            return Response({'tombstoned_ids': ids})
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[SYNC] ERROR getting tombstones: {str(e)}")
            debug_print(f"[SYNC] Traceback:\n{error_details}")
            
            logger.error("Tombstone retrieval failed.\n%s", error_details)
            return Response({'error': 'Failed to retrieve tombstones'}, status=500)
    
    @action(detail=False, methods=['post'], url_path='delete-account')
    def delete_account(self, request):
        start_time = __import__('time').time()
        user = request.user
        account_id = request.data.get('account_id')
        device_id = request.data.get('device_id', 'unknown')
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[SYNC] Delete account called")
        debug_print(f"[SYNC] User: {user.username} (ID: {user.id})")
        debug_print(f"[SYNC] Account ID: {account_id}")
        debug_print(f"[SYNC] Device ID: {device_id}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Delete account request - User: {user.username}, Account ID: {account_id}, Device: {device_id}")
        
        if not account_id:
            debug_print(f"[SYNC] ERROR: Missing account_id")
            logger.warning(f"Delete account missing account_id - User: {user.username}")
            return Response({'error': 'Account ID required'}, status=400)
        
        try:
            # Create tombstone record
            tombstone, created = AccountTombstone.objects.get_or_create(user=request.user, account_id=account_id)
            debug_print(f"[SYNC] Tombstone {'created' if created else 'already existed'} - ID: {tombstone.id}")
            
            # Also remove from EncryptedData if exists
            try:
                data = EncryptedData.objects.get(user=request.user, data_type='otp_accounts')
                deleted_accounts = json.loads(data.deleted_accounts) if data.deleted_accounts else []
                debug_print(f"[SYNC] Current deleted_accounts list length: {len(deleted_accounts)}")
                
                if account_id not in deleted_accounts:
                    deleted_accounts.append(account_id)
                    data.deleted_accounts = json.dumps(deleted_accounts)
                    data.save()
                    debug_print(f"[SYNC] Added account_id to deleted_accounts, new length: {len(deleted_accounts)}")
                else:
                    debug_print(f"[SYNC] Account_id already in deleted_accounts")
                    
            except EncryptedData.DoesNotExist:
                debug_print(f"[SYNC] No EncryptedData record found for otp_accounts")
            except Exception as e:
                debug_print(f"[SYNC] Error updating EncryptedData: {str(e)}")
            
            # Update sync log
            sync_log, created_log = SyncLog.objects.update_or_create(
                user=request.user,
                defaults={
                    'device_id': device_id,
                    'sync_type': 'delete',
                    'status': 'success',
                    'error_message': None,
                    'timestamp': timezone.now(),
                }
            )
            
            old_total = sync_log.total_syncs
            sync_log.total_syncs = sync_log.total_syncs + 1
            sync_log.save(update_fields=['total_syncs'])
            
            debug_print(f"[SYNC] Sync log updated - Total syncs: {old_total} -> {sync_log.total_syncs}")
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[SYNC] Account deletion completed in {elapsed_time:.2f} seconds")
            
            logger.info(f"Account deleted successfully - User: {user.username}, Account ID: {account_id}")
            
            return Response({'success': True, 'account_id': account_id})
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[SYNC] ERROR deleting account: {str(e)}")
            debug_print(f"[SYNC] Traceback:\n{error_details}")
            
            logger.error("Account deletion failed.\n%s", error_details)
            return Response({'error': 'Failed to delete account'}, status=500)
    
    @action(detail=False, methods=['post'], url_path='delete-all-accounts')
    def delete_all_accounts(self, request):
        start_time = __import__('time').time()
        user = request.user
        device_id = request.data.get('device_id', 'unknown')
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[SYNC] Delete all accounts called")
        debug_print(f"[SYNC] User: {user.username} (ID: {user.id})")
        debug_print(f"[SYNC] Device ID: {device_id}")
        debug_print(f"{'='*60}\n")
        
        logger.warning(f"Delete all accounts request - User: {user.username}, Device: {device_id}")
        
        try:
            # Delete all OTP accounts
            deleted_count, _ = EncryptedData.objects.filter(user=request.user, data_type='otp_accounts').delete()
            debug_print(f"[SYNC] Deleted {deleted_count} EncryptedData records")
            
            # Create global tombstone
            tombstone, created = AccountTombstone.objects.get_or_create(user=request.user, account_id='__ALL__')
            debug_print(f"[SYNC] Global tombstone {'created' if created else 'already existed'}")
            
            # Update sync log for delete all
            sync_log, created_log = SyncLog.objects.update_or_create(
                user=request.user,
                defaults={
                    'device_id': device_id,
                    'sync_type': 'delete_all',
                    'status': 'success',
                    'error_message': None,
                    'timestamp': timezone.now(),
                }
            )
            
            old_total = sync_log.total_syncs
            sync_log.total_syncs = sync_log.total_syncs + 1
            sync_log.save(update_fields=['total_syncs'])
            
            debug_print(f"[SYNC] Sync log updated - Total syncs: {old_total} -> {sync_log.total_syncs}")
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[SYNC] Delete all accounts completed in {elapsed_time:.2f} seconds")
            
            logger.warning(f"All accounts deleted - User: {user.username}, Deleted count: {deleted_count}")
            
            return Response({'success': True, 'deleted_count': deleted_count})
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[SYNC] ERROR deleting all accounts: {str(e)}")
            debug_print(f"[SYNC] Traceback:\n{error_details}")
            
            logger.error("Delete all accounts failed.\n%s", error_details)
            return Response({'error': 'Failed to delete accounts'}, status=500)


class AppNotificationViewSet(viewsets.ReadOnlyModelViewSet):
    permission_classes = [IsAuthenticated]
    serializer_class = AppNotificationSerializer

    def get_queryset(self):
        return AppNotification.objects.filter(user=self.request.user).order_by('-created_at')

    def list(self, request, *args, **kwargs):
        queryset = self.get_queryset()[:100]
        serializer = self.get_serializer(queryset, many=True)
        return Response(serializer.data)

    def retrieve(self, request, *args, **kwargs):
        notification = self.get_object()
        if not notification.is_read:
            notification.is_read = True
            notification.read_at = timezone.now()
            notification.save(update_fields=['is_read', 'read_at', 'updated_at'])
        serializer = self.get_serializer(notification)
        return Response(serializer.data)

    @action(detail=True, methods=['post'], url_path='mark-read')
    def mark_read(self, request, pk=None):
        notification = self.get_object()
        if not notification.is_read:
            notification.is_read = True
            notification.read_at = timezone.now()
            notification.save(update_fields=['is_read', 'read_at', 'updated_at'])
        return Response({'success': True})

    @action(detail=False, methods=['post'], url_path='mark-all-read')
    def mark_all_read(self, request):
        now = timezone.now()
        marked_count = AppNotification.objects.filter(
            user=request.user,
            is_read=False,
        ).update(
            is_read=True,
            read_at=now,
            updated_at=now,
        )
        return Response({'success': True, 'marked_count': marked_count})

    @action(detail=False, methods=['post'], url_path='clear')
    def clear(self, request):
        queryset = AppNotification.objects.filter(user=request.user)

        notification_type = (request.data.get('notification_type') or '').strip()
        if notification_type and notification_type != 'all':
            queryset = queryset.filter(notification_type=notification_type)

        keep_unread = request.data.get('keep_unread') is True
        if keep_unread:
            queryset = queryset.filter(is_read=True)

        older_than_days = request.data.get('older_than_days')
        if older_than_days not in (None, '', 'all'):
            try:
                days = int(older_than_days)
            except (TypeError, ValueError):
                return Response(
                    {'error': 'older_than_days must be a number.'},
                    status=400,
                )
            if days < 0:
                return Response(
                    {'error': 'older_than_days must be 0 or greater.'},
                    status=400,
                )
            cutoff = timezone.now() - timedelta(days=days)
            queryset = queryset.filter(created_at__lt=cutoff)

        deleted_count, _ = queryset.delete()
        return Response({'success': True, 'deleted_count': deleted_count})

    @action(detail=False, methods=['post'], url_path='log-event')
    def log_event(self, request):
        event_type = (request.data.get('event_type') or '').strip()

        if event_type == 'account_added':
            service_name = (request.data.get('service_name') or '').strip()
            account_label = (request.data.get('account_label') or '').strip()
            if not service_name:
                return Response({'error': 'service_name is required'}, status=400)

            create_account_added_notification(
                request.user,
                service_name=service_name,
                account_label=account_label or None,
            )
            return Response({'success': True}, status=201)

        if event_type == 'app_pin_changed':
            device_label = build_device_label(
                request.data.get('device_label'),
                request.META.get('HTTP_USER_AGENT'),
            )
            create_app_pin_changed_notification(
                request.user,
                device_label=device_label,
            )
            return Response({'success': True}, status=201)

        if event_type == 'accounts_imported':
            try:
                imported_count = int(request.data.get('imported_count') or 0)
                skipped_count = int(request.data.get('skipped_count') or 0)
            except (TypeError, ValueError):
                return Response({'error': 'imported_count must be a number'}, status=400)

            if imported_count <= 0:
                return Response({'error': 'imported_count must be greater than 0'}, status=400)

            create_accounts_imported_notification(
                request.user,
                imported_count=imported_count,
                skipped_count=max(0, skipped_count),
                source_label=(request.data.get('source_label') or '').strip() or None,
            )
            return Response({'success': True}, status=201)

        if event_type == 'passwords_imported':
            try:
                imported_count = int(request.data.get('imported_count') or 0)
            except (TypeError, ValueError):
                return Response({'error': 'imported_count must be a number'}, status=400)

            if imported_count <= 0:
                return Response({'error': 'imported_count must be greater than 0'}, status=400)

            create_passwords_imported_notification(
                request.user,
                imported_count=imported_count,
                source_label=(request.data.get('source_label') or '').strip() or None,
            )
            return Response({'success': True}, status=201)

        return Response({'error': 'Unsupported notification event'}, status=400)


class PasswordlessLoginRequestViewSet(viewsets.ReadOnlyModelViewSet):
    permission_classes = [IsAuthenticated]
    serializer_class = PasswordlessLoginRequestSerializer

    def get_queryset(self):
        _expire_stale_passwordless_requests(self.request.user)
        return PasswordlessLoginRequest.objects.filter(
            user=self.request.user,
        ).order_by('-created_at')

    def _ensure_primary_mobile_session(self):
        current_session = get_current_active_device_session(self.request)
        if current_session is None:
            return None, Response(
                {'error': 'This device could not be verified for passwordless approvals.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        if not current_session.is_primary:
            return None, Response(
                {'error': 'Only your current primary device can approve passwordless sign-ins.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        if current_session.device_kind != DeviceSession.DEVICE_KIND_MOBILE:
            return None, Response(
                {'error': 'Passwordless approvals must be completed from your primary phone.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        return current_session, None

    def list(self, request, *args, **kwargs):
        queryset = self.get_queryset()[:50]
        serializer = self.get_serializer(
            queryset,
            many=True,
            context={
                **self.get_serializer_context(),
                'passwordless_choice_builder': _build_passwordless_choices,
            },
        )
        return Response(serializer.data)

    @action(detail=True, methods=['post'], url_path='approve')
    def approve(self, request, pk=None):
        current_session, error_response = self._ensure_primary_mobile_session()
        if error_response is not None:
            return error_response

        login_request = self.get_object()
        if login_request.status != PasswordlessLoginRequest.STATUS_PENDING:
            return Response({'error': 'This sign-in request is no longer pending.'}, status=409)
        if login_request.expires_at <= timezone.now():
            login_request.status = PasswordlessLoginRequest.STATUS_EXPIRED
            login_request.save(update_fields=['status', 'updated_at'])
            return Response({'error': 'This sign-in request already expired.'}, status=410)

        selected_code = (request.data.get('selected_code') or '').strip()
        if not selected_code:
            return Response(
                {'error': 'Select the 3-digit code shown on the requesting device.'},
                status=400,
            )

        if not login_request.matches_verification_code(selected_code):
            return Response(
                {'error': 'That code does not match the requesting device.'},
                status=400,
            )

        login_request.status = PasswordlessLoginRequest.STATUS_APPROVED
        login_request.approved_at = timezone.now()
        login_request.reviewed_by_session = current_session
        login_request.save(update_fields=['status', 'approved_at', 'reviewed_by_session', 'updated_at'])
        return Response({'success': True})

    @action(detail=True, methods=['post'], url_path='deny')
    def deny(self, request, pk=None):
        current_session, error_response = self._ensure_primary_mobile_session()
        if error_response is not None:
            return error_response

        login_request = self.get_object()
        if login_request.status != PasswordlessLoginRequest.STATUS_PENDING:
            return Response({'error': 'This sign-in request is no longer pending.'}, status=409)

        login_request.status = PasswordlessLoginRequest.STATUS_DENIED
        login_request.reviewed_by_session = current_session
        login_request.save(update_fields=['status', 'reviewed_by_session', 'updated_at'])
        return Response({'success': True})

    @action(detail=True, methods=['post'], url_path='delete-log')
    def delete_log(self, request, pk=None):
        _, error_response = self._ensure_primary_mobile_session()
        if error_response is not None:
            return error_response

        login_request = self.get_object()
        if login_request.status == PasswordlessLoginRequest.STATUS_PENDING:
            return Response(
                {'error': 'Pending sign-in requests cannot be deleted.'},
                status=409,
            )

        login_request.delete()
        return Response({'success': True})

    @action(detail=False, methods=['post'], url_path='clear-logs')
    def clear_logs(self, request):
        _, error_response = self._ensure_primary_mobile_session()
        if error_response is not None:
            return error_response

        queryset = self.get_queryset().exclude(
            status=PasswordlessLoginRequest.STATUS_PENDING,
        )
        cleared_count = queryset.count()
        queryset.delete()
        return Response({'success': True, 'cleared_count': cleared_count})


class BulkAccountDeleteRequestViewSet(viewsets.ReadOnlyModelViewSet):
    permission_classes = [IsAuthenticated]
    serializer_class = BulkAccountDeleteRequestSerializer

    def get_queryset(self):
        _expire_stale_bulk_delete_requests(self.request.user)
        return BulkAccountDeleteRequest.objects.filter(
            user=self.request.user,
        ).order_by('-created_at')

    def _ensure_primary_session(self):
        current_session = get_current_active_device_session(self.request)
        if current_session is None:
            return None, Response(
                {'error': 'This device could not be verified for primary approvals.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        if not current_session.is_primary:
            return None, Response(
                {'error': 'Only your current primary device can approve OTP delete requests.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        return current_session, None

    def list(self, request, *args, **kwargs):
        queryset = self.get_queryset()[:50]
        serializer = self.get_serializer(queryset, many=True)
        return Response(serializer.data)

    @action(detail=False, methods=['post'], url_path='start')
    def start(self, request):
        current_session = get_current_active_device_session(request)
        primary_session = ensure_primary_session(request.user)
        if primary_session is None:
            return Response(
                {
                    'error': (
                        'OTP delete approval needs an active primary device. '
                        'Open BeatzLock on your primary device first.'
                    )
                },
                status=status.HTTP_409_CONFLICT,
            )

        account_ids = request.data.get('account_ids')
        if not isinstance(account_ids, list):
            return Response({'error': 'account_ids must be a list.'}, status=400)

        normalized_ids = []
        seen = set()
        for item in account_ids:
            account_id = str(item or '').strip()
            if not account_id or account_id in seen:
                continue
            seen.add(account_id)
            normalized_ids.append(account_id)

        if not normalized_ids:
            return Response({'error': 'Choose at least one account.'}, status=400)

        try:
            start_date = timezone.datetime.fromisoformat(
                str(request.data.get('range_start_date') or '')
            ).date()
            end_date = timezone.datetime.fromisoformat(
                str(request.data.get('range_end_date') or '')
            ).date()
        except Exception:
            return Response(
                {'error': 'range_start_date and range_end_date must be ISO dates.'},
                status=400,
            )

        if end_date < start_date:
            return Response(
                {'error': 'End date must be on or after the start date.'},
                status=400,
            )

        if current_session is not None and current_session.is_primary:
            return Response(
                {
                    'error': (
                        'Open the local confirmation flow on this primary device '
                        'instead of sending a remote approval request.'
                    )
                },
                status=status.HTTP_409_CONFLICT,
            )

        existing_pending = BulkAccountDeleteRequest.objects.filter(
            user=request.user,
            status=BulkAccountDeleteRequest.STATUS_PENDING,
        ).exists()
        if existing_pending:
            return Response(
                {'error': 'A delete approval request is already pending.'},
                status=status.HTTP_409_CONFLICT,
            )

        request_obj = BulkAccountDeleteRequest.objects.create(
            user=request.user,
            requester_device_id=get_request_device_id(request),
            requester_device_label=get_request_device_label(request),
            requester_device_kind=get_request_device_kind(request),
            requested_count=len(normalized_ids),
            range_start_date=start_date,
            range_end_date=end_date,
            account_ids=json.dumps(normalized_ids),
            expires_at=timezone.now() + timedelta(minutes=15),
        )

        create_bulk_delete_request_notification(
            request.user,
            requester_device_label=request_obj.requester_device_label,
            requested_count=request_obj.requested_count,
            range_start_date=request_obj.range_start_date.isoformat(),
            range_end_date=request_obj.range_end_date.isoformat(),
        )

        return Response(
            {
                'success': True,
                'request_id': str(request_obj.id),
                'primary_device_label': primary_session.device_label,
            },
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=['post'], url_path='approve')
    def approve(self, request, pk=None):
        current_session, error_response = self._ensure_primary_session()
        if error_response is not None:
            return error_response

        delete_request = self.get_object()
        if delete_request.status != BulkAccountDeleteRequest.STATUS_PENDING:
            return Response(
                {'error': 'This delete request is no longer pending.'},
                status=status.HTTP_409_CONFLICT,
            )
        if delete_request.expires_at <= timezone.now():
            delete_request.status = BulkAccountDeleteRequest.STATUS_EXPIRED
            delete_request.save(update_fields=['status', 'updated_at'])
            return Response({'error': 'This delete request already expired.'}, status=410)

        try:
            account_ids = json.loads(delete_request.account_ids or '[]')
        except Exception:
            account_ids = []
        deleted_count = _apply_account_tombstones(request.user, account_ids)

        delete_request.status = BulkAccountDeleteRequest.STATUS_COMPLETED
        delete_request.approved_at = timezone.now()
        delete_request.completed_at = timezone.now()
        delete_request.reviewed_by_session = current_session
        delete_request.save(
            update_fields=[
                'status',
                'approved_at',
                'completed_at',
                'reviewed_by_session',
                'updated_at',
            ]
        )
        return Response({'success': True, 'deleted_count': deleted_count})

    @action(detail=True, methods=['post'], url_path='deny')
    def deny(self, request, pk=None):
        current_session, error_response = self._ensure_primary_session()
        if error_response is not None:
            return error_response

        delete_request = self.get_object()
        if delete_request.status != BulkAccountDeleteRequest.STATUS_PENDING:
            return Response(
                {'error': 'This delete request is no longer pending.'},
                status=status.HTTP_409_CONFLICT,
            )

        delete_request.status = BulkAccountDeleteRequest.STATUS_DENIED
        delete_request.reviewed_by_session = current_session
        delete_request.save(
            update_fields=['status', 'reviewed_by_session', 'updated_at']
        )
        return Response({'success': True})


@api_view(['POST'])
@authentication_classes([])
@permission_classes([AllowAny])
def receive_external_review_reply(request):
    configured_secret = settings.BEATZLOCK_INTERNAL_SERVICE_SECRET
    provided_secret = request.headers.get('X-BeatzLock-Service-Secret', '')

    if not configured_secret or not constant_time_compare(
        provided_secret,
        configured_secret,
    ):
        return Response({'error': 'Forbidden'}, status=status.HTTP_403_FORBIDDEN)

    user_id = str(request.data.get('user_id') or '').strip()
    email = str(request.data.get('email') or '').strip().lower()
    platform_label = str(request.data.get('platform_label') or 'Unknown').strip() or 'Unknown'
    admin_reply = str(request.data.get('admin_reply') or '').strip()
    display_name = str(request.data.get('display_name') or '').strip()

    try:
        stars = int(request.data.get('stars') or 0)
    except (TypeError, ValueError):
        stars = 0

    if not admin_reply:
        return Response({'error': 'admin_reply is required'}, status=status.HTTP_400_BAD_REQUEST)

    user = None
    if user_id:
        user = User.objects.filter(id=user_id).first()
    if user is None and email:
        user = User.objects.filter(email__iexact=email).first()
    if user is None:
        return Response({'error': 'User not found'}, status=status.HTTP_404_NOT_FOUND)

    notification = create_app_review_reply_notification(
        user,
        platform_label=platform_label,
        stars=max(1, min(stars or 1, 5)),
        admin_reply=admin_reply,
        display_name=display_name or None,
    )
    return Response(
        {
            'success': True,
            'notification_id': notification.id,
            'user_id': user.id,
        },
        status=status.HTTP_201_CREATED,
    )


class DeviceSessionViewSet(viewsets.ReadOnlyModelViewSet):
    permission_classes = [IsAuthenticated]
    serializer_class = DeviceSessionSerializer

    def get_queryset(self):
        return DeviceSession.objects.filter(
            user=self.request.user,
            is_active=True,
            revoked_at__isnull=True,
        ).order_by('-last_seen_at', '-created_at')

    def _ensure_current_session(self):
        session = get_current_active_device_session(self.request)
        if session is not None:
            current_device_id = get_request_device_id(self.request)
            current_device_fingerprint = get_request_device_fingerprint(self.request)
            if current_device_id or current_device_fingerprint:
                return ensure_device_session(
                    self.request.user,
                    device_id=current_device_id,
                    device_fingerprint=current_device_fingerprint,
                    device_label=get_request_device_label(self.request),
                    device_kind=get_request_device_kind(self.request),
                    user_agent=self.request.META.get('HTTP_USER_AGENT', ''),
                    ip_address=extract_request_ip(self.request),
                )

            session.device_label = get_request_device_label(self.request)
            session.device_kind = get_request_device_kind(self.request)
            session.user_agent = self.request.META.get('HTTP_USER_AGENT', '') or session.user_agent
            session.ip_address = extract_request_ip(self.request) or session.ip_address
            session.last_seen_at = timezone.now()
            session.save(
                update_fields=[
                    'device_label',
                    'device_kind',
                    'user_agent',
                    'ip_address',
                    'last_seen_at',
                    'updated_at',
                ]
            )
            return session

        current_device_id = get_request_device_id(self.request)
        current_device_fingerprint = get_request_device_fingerprint(self.request)
        if not current_device_id and not current_device_fingerprint:
            return None

        had_revoked_session = DeviceSession.objects.filter(
            user=self.request.user,
            device_id=current_device_id,
        ).filter(is_active=False).exists() or DeviceSession.objects.filter(
            user=self.request.user,
            device_id=current_device_id,
            revoked_at__isnull=False,
        ).exists()
        if had_revoked_session:
            raise AuthenticationFailed(
                'This device session has been signed out.',
                code='session_revoked',
            )

        return ensure_device_session(
            self.request.user,
            device_id=current_device_id,
            device_fingerprint=current_device_fingerprint,
            device_label=get_request_device_label(self.request),
            device_kind=get_request_device_kind(self.request),
            user_agent=self.request.META.get('HTTP_USER_AGENT', ''),
            ip_address=extract_request_ip(self.request),
        )

    def list(self, request, *args, **kwargs):
        current_session = self._ensure_current_session()
        ensure_primary_session(request.user)
        queryset = self.get_queryset()[:25]
        create_daily_active_devices_notification(
            request.user,
            active_count=queryset.count(),
        )
        serializer = self.get_serializer(
            queryset,
            many=True,
            context={
                **self.get_serializer_context(),
                'current_session_id': str(current_session.id) if current_session else request.auth.get('session_id'),
                'current_device_id': get_request_device_id(request),
                'current_device_fingerprint': get_request_device_fingerprint(request),
            },
        )
        return Response(serializer.data)

    @action(detail=True, methods=['post'], url_path='revoke')
    def revoke(self, request, pk=None):
        current_session = self._ensure_current_session()
        session = self.get_object()
        current_session_id = str(current_session.id) if current_session else str(request.auth.get('session_id', ''))

        if current_session_id and str(session.id) == current_session_id:
            return Response(
                {'error': 'Use the normal logout button to sign out this current device.'},
                status=400,
            )

        if session.is_primary:
            return Response(
                {'error': 'The primary device cannot be signed out remotely from another device.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        session.is_active = False
        session.is_primary = False
        session.revoked_at = timezone.now()
        session.save(update_fields=['is_active', 'is_primary', 'revoked_at', 'updated_at'])
        ensure_primary_session(request.user)
        return Response({'success': True})

    @action(detail=False, methods=['post'], url_path='revoke-others')
    def revoke_others(self, request):
        current_session = self._ensure_current_session()
        queryset = self.get_queryset()

        if current_session is not None:
            queryset = queryset.exclude(id=current_session.id)
        else:
            current_session_id = request.auth.get('session_id')
            current_device_id = get_request_device_id(request)
            if current_session_id:
                queryset = queryset.exclude(id=current_session_id)
            elif current_device_id:
                queryset = queryset.exclude(device_id=current_device_id)

        queryset = queryset.exclude(is_primary=True)

        now = timezone.now()
        revoked_count = queryset.update(
            is_active=False,
            is_primary=False,
            revoked_at=now,
            updated_at=now,
        )
        ensure_primary_session(request.user)
        return Response({'success': True, 'revoked_count': revoked_count})

    @action(detail=True, methods=['post'], url_path='set-primary')
    def set_primary(self, request, pk=None):
        current_session = self._ensure_current_session()
        session = self.get_object()

        if current_session is None:
            return Response(
                {'error': 'This device could not be verified for primary device changes.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        if not current_session.is_primary:
            return Response(
                {'error': 'Only the device currently set as primary can change the primary device.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        password = request.data.get('password') or ''
        if not password:
            return Response(
                {'error': 'Enter your account password to change the primary device.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if not request.user.check_password(password):
            return Response(
                {'error': 'Account password is incorrect.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        has_active_mobile_session = DeviceSession.objects.filter(
            user=request.user,
            is_active=True,
            revoked_at__isnull=True,
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
        ).exists()
        if has_active_mobile_session and session.device_kind != DeviceSession.DEVICE_KIND_MOBILE:
            return Response(
                {
                    'error': 'Choose a phone as your primary device so passwordless approvals can stay on mobile.',
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        DeviceSession.objects.filter(
            user=request.user,
            is_active=True,
            revoked_at__isnull=True,
            is_primary=True,
        ).exclude(id=session.id).update(
            is_primary=False,
            updated_at=timezone.now(),
        )

        if not session.is_primary:
            session.is_primary = True
            session.save(update_fields=['is_primary', 'updated_at'])

        return Response({'success': True})

    @action(detail=False, methods=['post'], url_path='heartbeat')
    def heartbeat(self, request):
        current_session = self._ensure_current_session()
        ensure_primary_session(request.user)
        active_count = self.get_queryset().count()
        create_daily_active_devices_notification(
            request.user,
            active_count=active_count,
        )
        return Response({
            'success': True,
            'active_count': active_count,
            'current_session_id': str(current_session.id) if current_session else request.auth.get('session_id'),
        })

    @action(detail=False, methods=['post'], url_path='logout-current')
    def logout_current(self, request):
        current_session = self._ensure_current_session()
        if current_session is None:
            session_id = request.auth.get('session_id')
            current_session = DeviceSession.objects.filter(
                id=session_id,
                user=request.user,
                is_active=True,
                revoked_at__isnull=True,
            ).first()

        if current_session is not None:
            current_session.is_active = False
            current_session.is_primary = False
            current_session.revoked_at = timezone.now()
            current_session.save(update_fields=['is_active', 'is_primary', 'revoked_at', 'updated_at'])
            ensure_primary_session(request.user)

        return Response({'success': True})


# ===================
# DELETE OTP VIEWS
# ===================
@api_view(['POST'])
@permission_classes([IsAuthenticated])
def send_delete_otp(request):
    start_time = __import__('time').time()
    user = request.user
    
    debug_print(f"\n{'='*60}")
    debug_print(f"[DELETE OTP] Send OTP called")
    debug_print(f"[DELETE OTP] User: {user.username} (ID: {user.id})")
    debug_print(f"[DELETE OTP] Email: {user.email}")
    debug_print(f"[DELETE OTP] Request IP: {request.META.get('REMOTE_ADDR')}")
    debug_print(f"{'='*60}\n")
    
    logger.info(f"Delete OTP request - User: {user.username}, IP: {request.META.get('REMOTE_ADDR')}")
    
    if not user.email:
        debug_print(f"[DELETE OTP] ERROR: User has no email")
        logger.error("Delete OTP cannot be sent because the account has no email address.")
        return Response({'success': False, 'error': 'No email associated with account'}, status=400)
    
    try:
        # Generate 6-digit code
        code = ''.join(random.choices(string.digits, k=6))
        debug_print(f"[DELETE OTP] Generated code: {code}")
        
        # Delete old unused codes for this user
        old_codes_deleted = DeleteOTPCode.objects.filter(user=user, used=False).delete()
        debug_print(f"[DELETE OTP] Deleted {old_codes_deleted[0]} old unused codes")
        
        # Create new OTP
        otp_obj = DeleteOTPCode.objects.create(user=user, code=code)
        debug_print(f"[DELETE OTP] Created OTP record - ID: {otp_obj.id}")
        
        # Get email template
        html_message = get_delete_otp_email_template(user.username, code)
        
        debug_print(f"[DELETE OTP] Sending email to: {user.email}")
        
        send_transactional_email(
            subject='BeatzLock Confirm Delete All Accounts',
            recipient=user.email,
            text_content=get_delete_otp_email_text(user.username, code),
            html_content=html_message,
            fail_silently=False,
        )
        
        elapsed_time = __import__('time').time() - start_time
        debug_print(f"[DELETE OTP] Email sent successfully in {elapsed_time:.2f} seconds")
        
        logger.info(f"Delete OTP sent successfully - User: {user.username}, Code: {code}")
        
        return Response({'success': True, 'message': f'Verification code sent to {user.email}'})
        
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"[DELETE OTP] ERROR: {str(e)}")
        debug_print(f"[DELETE OTP] Traceback:\n{error_details}")
        
        logger.error("Delete OTP sending failed.\n%s", error_details)
        print(f"Send delete OTP error: {e}")  # Keep original print for console
        
        return Response({'success': False, 'error': str(e)}, status=500)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def verify_delete_otp(request):
    start_time = __import__('time').time()
    user = request.user
    code = request.data.get('code', '')
    
    debug_print(f"\n{'='*60}")
    debug_print(f"[DELETE OTP] Verify OTP called")
    debug_print(f"[DELETE OTP] User: {user.username} (ID: {user.id})")
    debug_print(f"[DELETE OTP] Code: {code}")
    debug_print(f"{'='*60}\n")
    
    logger.info(f"Delete OTP verification - User: {user.username}, Code provided: {bool(code)}")
    
    if not code:
        debug_print(f"[DELETE OTP] ERROR: No code provided")
        logger.warning(f"Delete OTP verification - No code provided for user: {user.username}")
        return Response({'success': False, 'error': 'Code is required'}, status=400)
    
    try:
        # Find the latest unused OTP for this user
        otp_obj = DeleteOTPCode.objects.filter(
            user=user, 
            code=code, 
            used=False
        ).order_by('-created_at').first()
        
        if not otp_obj:
            debug_print(f"[DELETE OTP] No valid OTP found for code: {code}")
            logger.warning(f"Invalid delete OTP attempt - User: {user.username}, Code: {code}")
            return Response({'success': False, 'error': 'Invalid or expired code'}, status=400)
        
        debug_print(f"[DELETE OTP] Found OTP - ID: {otp_obj.id}, Created: {otp_obj.created_at}")
        
        # Check if OTP is valid
        if otp_obj.is_valid():
            debug_print(f"[DELETE OTP] OTP is valid, marking as used")
            otp_obj.used = True
            otp_obj.save()
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[DELETE OTP] OTP verified successfully in {elapsed_time:.2f} seconds")
            
            logger.info(f"Delete OTP verified successfully - User: {user.username}")
            return Response({'success': True, 'message': 'Code verified successfully'})
        else:
            debug_print(f"[DELETE OTP] OTP has expired - Created: {otp_obj.created_at}")
            logger.warning(f"Delete OTP expired - User: {user.username}, Created: {otp_obj.created_at}")
            return Response({'success': False, 'error': 'Code has expired (10 minute limit)'}, status=400)
        
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"[DELETE OTP] ERROR: {str(e)}")
        debug_print(f"[DELETE OTP] Traceback:\n{error_details}")
        
        logger.error("Delete OTP verification failed.\n%s", error_details)
        return Response({'success': False, 'error': str(e)}, status=500)


# ===================
# SYNC PREFERENCE VIEWS
# ===================
@api_view(['POST'])
@permission_classes([IsAuthenticated])
def set_sync_preference(request):
    start_time = __import__('time').time()
    user = request.user
    enabled = request.data.get('sync_enabled', True)
    
    debug_print(f"\n{'='*60}")
    debug_print(f"[SYNC PREF] Set preference called")
    debug_print(f"[SYNC PREF] User: {user.username} (ID: {user.id})")
    debug_print(f"[SYNC PREF] Sync enabled: {enabled}")
    debug_print(f"{'='*60}\n")
    
    logger.info(f"Set sync preference - User: {user.username}, Enabled: {enabled}")
    
    try:
        obj, created = EncryptedData.objects.get_or_create(
            user=request.user,
            data_type='sync_preference',
            defaults={
                'encrypted_content': 'true' if enabled else 'false',
                'synced_at': timezone.now(),
                'deleted_accounts': 'N/A',
                'version': 1
            }
        )
        
        debug_print(f"[SYNC PREF] Record {'created' if created else 'retrieved'} - ID: {obj.id}, Version: {obj.version}")
        
        if not created:
            old_value = obj.encrypted_content
            obj.encrypted_content = 'true' if enabled else 'false'
            obj.synced_at = timezone.now()
            obj.deleted_accounts = 'N/A'
            obj.version += 1
            obj.save()
            debug_print(f"[SYNC PREF] Updated preference - Old: {old_value}, New: {obj.encrypted_content}, New Version: {obj.version}")
        
        elapsed_time = __import__('time').time() - start_time
        debug_print(f"[SYNC PREF] Preference saved in {elapsed_time:.2f} seconds")
        
        logger.info(f"Sync preference saved - User: {user.username}, Enabled: {enabled}, Version: {obj.version}")
        
        return Response({
            'success': True,
            'sync_enabled': enabled,
            'version': obj.version,
            'synced_at': obj.synced_at
        })
        
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"[SYNC PREF] ERROR: {str(e)}")
        debug_print(f"[SYNC PREF] Traceback:\n{error_details}")
        
        logger.error("Saving sync preference failed.\n%s", error_details)
        return Response({'error': str(e)}, status=500)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def get_sync_preference(request):
    start_time = __import__('time').time()
    user = request.user
    
    debug_print(f"\n{'='*60}")
    debug_print(f"[SYNC PREF] Get preference called")
    debug_print(f"[SYNC PREF] User: {user.username} (ID: {user.id})")
    debug_print(f"{'='*60}\n")
    
    logger.info(f"Get sync preference - User: {user.username}")
    
    try:
        data = EncryptedData.objects.get(user=request.user, data_type='sync_preference')
        enabled = data.encrypted_content == 'true'
        
        debug_print(f"[SYNC PREF] Retrieved preference - Enabled: {enabled}, Version: {data.version}")
        
        elapsed_time = __import__('time').time() - start_time
        debug_print(f"[SYNC PREF] Preference retrieved in {elapsed_time:.2f} seconds")
        
        return Response({'sync_enabled': enabled})
        
    except EncryptedData.DoesNotExist:
        debug_print(f"[SYNC PREF] No preference found, returning default (True)")
        logger.info(f"No sync preference for user {user.username}, using default True")
        return Response({'sync_enabled': True})
        
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"[SYNC PREF] ERROR: {str(e)}")
        debug_print(f"[SYNC PREF] Traceback:\n{error_details}")
        
        logger.error("Reading sync preference failed.\n%s", error_details)
        return Response({'sync_enabled': True})  # Return default on error


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def download_backup_codes(request):
    start_time = __import__('time').time()
    user = request.user

    debug_print(f"\n{'='*60}")
    debug_print("[BACKUP CODES] Download requested")
    debug_print(f"[BACKUP CODES] User: {user.username} (ID: {user.id})")
    debug_print(f"{'='*60}\n")

    logger.info("Backup code PDF download - User: %s", user.username)

    try:
        primary_session = ensure_primary_session(user)
        current_session = get_current_active_device_session(request)
        if current_session is None:
            return Response(
                {'error': 'This device could not be verified for backup code generation.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        if not current_session.is_primary:
            primary_device_label = (
                primary_session.device_label
                if primary_session is not None
                else 'your current primary device'
            )
            return Response(
                {
                    'error': (
                        'Recovery codes can only be generated from your primary device. '
                        f'Your primary device is {primary_device_label}.'
                    ),
                    'primary_device': {
                        'id': str(primary_session.id) if primary_session is not None else None,
                        'device_id': primary_session.device_id if primary_session is not None else '',
                        'device_label': primary_device_label,
                    },
                    'primary_device_label': primary_device_label,
                },
                status=status.HTTP_403_FORBIDDEN,
            )

        codes = generate_backup_codes()
        entries = build_backup_code_entries(codes)
        encrypted_codes = encrypt_backup_codes(entries)

        code_set = BackupCodeSet.objects.filter(user=user).first()
        if code_set is None:
            code_set = BackupCodeSet.objects.create(
                user=user,
                encrypted_codes=encrypted_codes,
                last_used_at=None,
            )
        else:
            code_set.encrypted_codes = encrypted_codes
            code_set.last_used_at = None
            code_set.save(update_fields=['encrypted_codes', 'last_used_at', 'updated_at'])
        debug_print("[BACKUP CODES] Generated fresh backup codes and invalidated previous ones")

        generated_at = timezone.localtime(timezone.now()).strftime('%B %d, %Y at %I:%M %p %Z')

        pdf_bytes = build_backup_codes_pdf(
            email=user.email or user.username,
            account_name='BeatzLock Auth',
            codes=codes,
            generated_at=generated_at,
            generated_from=current_session.device_label or 'Primary device',
            theme=get_request_pdf_theme(request),
        )

        safe_username = ''.join(
            char for char in user.username if char.isalnum() or char in ('-', '_')
        ) or 'user'
        filename = f"beatzlock_backup_codes_{safe_username}.pdf"
        response = HttpResponse(pdf_bytes, content_type='application/pdf')
        response['Content-Disposition'] = f'attachment; filename="{filename}"'
        response['Content-Length'] = str(len(pdf_bytes))

        if user.email:
            html_content = get_recovery_codes_generated_email_template(
                user.username,
                generated_at=generated_at,
                device_label=current_session.device_label or '',
            )
            send_transactional_email(
                subject='New recovery codes generated - BeatzLock Authenticator',
                recipient=user.email,
                text_content=get_recovery_codes_generated_email_text(
                    user.username,
                    generated_at=generated_at,
                    device_label=current_session.device_label or '',
                ),
                html_content=html_content,
                fail_silently=True,
            )

        create_recovery_codes_generated_notification(
            user,
            device_label=current_session.device_label,
            generated_at=generated_at,
        )

        elapsed_time = __import__('time').time() - start_time
        debug_print(f"[BACKUP CODES] PDF ready in {elapsed_time:.2f} seconds")
        logger.info("Backup code PDF ready - User: %s", user.username)
        return response

    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"[BACKUP CODES] ERROR: {str(e)}")
        debug_print(f"[BACKUP CODES] Traceback:\n{error_details}")
        logger.error("Backup code PDF generation failed.\n%s", error_details)
        return Response({'error': 'Failed to generate backup codes PDF'}, status=500)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def get_backup_code_status(request):
    user = request.user

    try:
        code_set = BackupCodeSet.objects.filter(user=user).first()
        if code_set is None or not code_set.encrypted_codes:
            return Response({
                'has_codes': False,
                'remaining_codes': 0,
                'total_codes': 3,
                'last_used_at': None,
            })

        entries = normalize_backup_code_entries(
            decrypt_backup_codes(code_set.encrypted_codes)
        )
        return Response({
            'has_codes': True,
            'remaining_codes': remaining_backup_codes(entries),
            'total_codes': len(entries),
            'last_used_at': code_set.last_used_at.isoformat()
            if code_set.last_used_at else None,
        })
    except Exception as e:
        error_details = traceback.format_exc()
        debug_print(f"[BACKUP CODES] STATUS ERROR: {str(e)}")
        debug_print(f"[BACKUP CODES] STATUS TRACEBACK:\n{error_details}")
        logger.error("Backup code status failed.\n%s", error_details)
        return Response({'error': 'Failed to read backup code status'}, status=500)
