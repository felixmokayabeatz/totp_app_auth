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
    DeviceSession,
    EncryptedData,
    SyncLog,
    AccountTombstone,
    DeleteOTPCode,
    BackupCodeSet,
)
from .notifications import (
    build_device_label,
    create_account_added_notification,
    create_app_pin_changed_notification,
    create_app_review_reply_notification,
    create_daily_active_devices_notification,
    create_password_changed_notification,
    create_recovery_codes_generated_notification,
    create_sign_in_notification,
)
from .device_sessions import (
    attach_session_to_refresh_token,
    ensure_primary_session,
    ensure_device_session,
    extract_request_ip,
    get_request_device_id,
    get_request_device_label,
)
from .serializers import (
    AppNotificationSerializer,
    DeviceSessionSerializer,
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

# ===================
# LOGGING SETUP
# ===================
logger = logging.getLogger(__name__)


def debug_print(*args, **kwargs):
    """Conditional print only when DEBUG=True"""
    if django_settings.DEBUG:
        print(*args, **kwargs)


def get_current_active_device_session(request):
    auth = getattr(request, 'auth', None)
    session_id = auth.get('session_id') if hasattr(auth, 'get') else None

    if session_id:
        session = DeviceSession.objects.filter(
            id=session_id,
            user=request.user,
            is_active=True,
            revoked_at__isnull=True,
        ).first()
        if session is not None:
            return session

    device_id = get_request_device_id(request)
    if not device_id:
        return None

    return DeviceSession.objects.filter(
        user=request.user,
        device_id=device_id,
        is_active=True,
        revoked_at__isnull=True,
    ).order_by('-last_seen_at', '-created_at').first()


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
            cutoff = timezone.now() - timezone.timedelta(days=days)
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

        return Response({'error': 'Unsupported notification event'}, status=400)


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
            session.device_label = get_request_device_label(self.request)
            session.user_agent = self.request.META.get('HTTP_USER_AGENT', '') or session.user_agent
            session.ip_address = extract_request_ip(self.request) or session.ip_address
            session.last_seen_at = timezone.now()
            session.save(
                update_fields=[
                    'device_label',
                    'user_agent',
                    'ip_address',
                    'last_seen_at',
                    'updated_at',
                ]
            )
            return session

        current_device_id = get_request_device_id(self.request)
        if not current_device_id:
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
            device_label=get_request_device_label(self.request),
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

        pdf_bytes = build_backup_codes_pdf(
            email=user.email or user.username,
            account_name='BeatzLock Auth',
            codes=codes,
        )

        safe_username = ''.join(
            char for char in user.username if char.isalnum() or char in ('-', '_')
        ) or 'user'
        filename = f"beatzlock_backup_codes_{safe_username}.pdf"
        response = HttpResponse(pdf_bytes, content_type='application/pdf')
        response['Content-Disposition'] = f'attachment; filename="{filename}"'
        response['Content-Length'] = str(len(pdf_bytes))

        if user.email:
            html_content = get_recovery_codes_generated_email_template(user.username)
            send_transactional_email(
                subject='New recovery codes generated - BeatzLock Authenticator',
                recipient=user.email,
                text_content=get_recovery_codes_generated_email_text(user.username),
                html_content=html_content,
                fail_silently=True,
            )

        create_recovery_codes_generated_notification(user)

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
