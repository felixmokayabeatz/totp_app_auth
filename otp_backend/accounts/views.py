from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework_simplejwt.tokens import RefreshToken
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from api.models import EncryptedData
from .serializers import UserSerializer, EncryptedDataSerializer, RegisterSerializer
from .models import UserProfile
from .serializers import UserProfileSerializer
import logging
import traceback
from django.conf import settings as django_settings

logger = logging.getLogger(__name__)


def debug_print(*args, **kwargs):
    """Conditional print only when DEBUG=True"""
    if django_settings.DEBUG:
        print(*args, **kwargs)


class ProfileViewSet(viewsets.GenericViewSet):
    permission_classes = [IsAuthenticated]
    
    @action(detail=False, methods=['get'])
    def my_profile(self, request):
        debug_print(f"\n{'='*60}")
        debug_print(f"[PROFILE] my_profile called for user: {request.user.username}")
        debug_print(f"[PROFILE] User ID: {request.user.id}")
        debug_print(f"[PROFILE] Request IP: {request.META.get('REMOTE_ADDR')}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Profile view - User: {request.user.username}, IP: {request.META.get('REMOTE_ADDR')}")
        
        try:
            serializer = UserSerializer(request.user)
            debug_print(f"[PROFILE] Profile data retrieved successfully")
            return Response(serializer.data)
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[PROFILE] ERROR: {str(e)}")
            logger.error("Profile view failed.\n%s", error_details)
            return Response({'error': str(e)}, status=500)
    
    @action(detail=False, methods=['post'])
    def update_profile(self, request):
        debug_print(f"\n{'='*60}")
        debug_print(f"[PROFILE] update_profile called for user: {request.user.username}")
        debug_print(f"[PROFILE] Request data keys: {list(request.data.keys())}")
        debug_print(f"[PROFILE] Files: {list(request.FILES.keys())}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Profile update - User: {request.user.username}, IP: {request.META.get('REMOTE_ADDR')}")
        
        try:
            profile, created = UserProfile.objects.get_or_create(user=request.user)
            debug_print(f"[PROFILE] Profile {'created' if created else 'retrieved'} for user")
            
            if 'profile_photo' in request.FILES:
                debug_print(f"[PROFILE] Updating profile photo: {request.FILES['profile_photo'].name}")
                profile.profile_photo = request.FILES['profile_photo']
            
            if 'bio' in request.data:
                debug_print(f"[PROFILE] Updating bio: {request.data['bio'][:50]}...")
                profile.bio = request.data['bio']
            
            if 'encryption_public_key' in request.data:
                debug_print(f"[PROFILE] Updating encryption public key (length: {len(request.data['encryption_public_key'])})")
                profile.encryption_public_key = request.data['encryption_public_key']
            
            if 'encryption_private_key' in request.data:
                debug_print(f"[PROFILE] Updating encryption private key (length: {len(request.data['encryption_private_key'])})")
                profile.encryption_private_key = request.data['encryption_private_key']
            
            profile.save()
            debug_print(f"[PROFILE] Profile updated successfully")
            
            serializer = UserProfileSerializer(profile)
            logger.info(f"Profile updated for user: {request.user.username}")
            
            return Response(serializer.data)
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[PROFILE] ERROR updating profile: {str(e)}")
            debug_print(f"[PROFILE] Traceback:\n{error_details}")
            logger.error("Profile update failed.\n%s", error_details)
            return Response({'error': str(e)}, status=500)


class AuthViewSet(viewsets.GenericViewSet):
    permission_classes = [AllowAny]
    serializer_class = RegisterSerializer
    
    @action(detail=False, methods=['post'])
    def register(self, request):
        start_time = __import__('time').time()
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[AUTH] Register called")
        debug_print(f"[AUTH] Request data: username={request.data.get('username')}, email={request.data.get('email')}")
        debug_print(f"[AUTH] Request IP: {request.META.get('REMOTE_ADDR')}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Registration attempt - IP: {request.META.get('REMOTE_ADDR')}, Username: {request.data.get('username')}")
        
        serializer = RegisterSerializer(data=request.data)
        if serializer.is_valid():
            debug_print(f"[AUTH] Registration data is valid")
            
            try:
                user = serializer.save()
                debug_print(f"[AUTH] User created successfully - ID: {user.id}, Username: {user.username}")
                
                refresh = RefreshToken.for_user(user)
                
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
        
        debug_print(f"[AUTH] Registration validation failed: {serializer.errors}")
        logger.warning(f"Registration failed - Errors: {serializer.errors}")
        return Response(serializer.errors, status=400)
    
    @action(detail=False, methods=['post'])
    def login(self, request):
        start_time = __import__('time').time()
        username = (request.data.get('username') or '').strip()
        password = request.data.get('password')
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[AUTH] Login called")
        debug_print(f"[AUTH] Username: {username}")
        debug_print(f"[AUTH] Password provided: {'Yes' if password else 'No'}")
        debug_print(f"[AUTH] Request IP: {request.META.get('REMOTE_ADDR')}")
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
                debug_print(f"[AUTH] User found: {auth_username} (ID: {user_obj.id})")
            except User.DoesNotExist:
                debug_print(f"[AUTH] User not found, using provided username for authentication")
                auth_username = username
            
            debug_print(f"[AUTH] Authenticating with username: {auth_username}")
            user = authenticate(username=auth_username, password=password)
            
            if user:
                debug_print(f"[AUTH] Authentication SUCCESS for user: {user.username}")
                
                refresh = RefreshToken.for_user(user)
                
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


class SyncViewSet(viewsets.GenericViewSet):
    permission_classes = [IsAuthenticated]
    serializer_class = EncryptedDataSerializer
    
    @action(detail=False, methods=['post'])
    def sync(self, request):
        start_time = __import__('time').time()
        user = request.user
        data_type = request.data.get('data_type')
        device_id = request.data.get('device_id', 'unknown')
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[SYNC] sync called")
        debug_print(f"[SYNC] User: {user.username} (ID: {user.id})")
        debug_print(f"[SYNC] Data type: {data_type}")
        debug_print(f"[SYNC] Device ID: {device_id}")
        debug_print(f"[SYNC] Content length: {len(request.data.get('encrypted_content', ''))}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Sync request - User: {user.username}, Type: {data_type}, Device: {device_id}")
        
        try:
            encrypted_content = request.data.get('encrypted_content')
            version = request.data.get('version', 1)
            deleted_accounts = request.data.get('deleted_accounts', '[]')
            
            debug_print(f"[SYNC] Version: {version}")
            debug_print(f"[SYNC] Deleted accounts: {deleted_accounts[:100]}...")
            
            obj, created = EncryptedData.objects.update_or_create(
                user=request.user,
                data_type=data_type,
                defaults={
                    'encrypted_content': encrypted_content,
                    'version': version,
                    'synced_at': __import__('django.utils.timezone').now(),
                    'deleted_accounts': deleted_accounts,
                }
            )
            
            debug_print(f"[SYNC] Record {'created' if created else 'updated'} - ID: {obj.id}")
            
            # Update sync log
            sync_log, created_log = SyncLog.objects.update_or_create(
                user=request.user,
                defaults={
                    'device_id': device_id,
                    'sync_type': 'upload',
                    'status': 'success',
                    'error_message': None,
                    'timestamp': __import__('django.utils.timezone').now(),
                }
            )
            sync_log.total_syncs = sync_log.total_syncs + 1
            sync_log.save(update_fields=['total_syncs'])
            
            debug_print(f"[SYNC] Sync log updated - Total syncs: {sync_log.total_syncs}")
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[SYNC] Sync completed in {elapsed_time:.2f} seconds")
            
            logger.info(f"Sync successful - User: {user.username}, Type: {data_type}, Created: {created}, Total syncs: {sync_log.total_syncs}")
            
            return Response({
                'status': 'synced', 
                'version': obj.version,
                'synced_at': obj.synced_at.isoformat() if obj.synced_at else None,
                'deleted_accounts': obj.deleted_accounts,
            })
            
        except Exception as e:
            error_details = traceback.format_exc()
            debug_print(f"[SYNC] ERROR during sync: {str(e)}")
            debug_print(f"[SYNC] Traceback:\n{error_details}")
            
            logger.error("Sync failed.\n%s", error_details)
            return Response({'error': 'Sync failed', 'details': str(e) if django_settings.DEBUG else 'Internal error'}, status=500)
    
    @action(detail=False, methods=['get'], url_path='get-data')
    def get_data(self, request):
        start_time = __import__('time').time()
        user = request.user
        data_type = request.query_params.get('data_type')
        device_id = request.query_params.get('device_id', 'unknown')
        
        debug_print(f"\n{'='*60}")
        debug_print(f"[SYNC] get_data called")
        debug_print(f"[SYNC] User: {user.username} (ID: {user.id})")
        debug_print(f"[SYNC] Data type: {data_type}")
        debug_print(f"[SYNC] Device ID: {device_id}")
        debug_print(f"{'='*60}\n")
        
        logger.info(f"Get data request - User: {user.username}, Type: {data_type}, Device: {device_id}")
        
        try:
            data = EncryptedData.objects.get(user=request.user, data_type=data_type)
            debug_print(f"[SYNC] Data found - ID: {data.id}, Version: {data.version}")
            
            # Update sync log
            sync_log, created_log = SyncLog.objects.update_or_create(
                user=request.user,
                defaults={
                    'device_id': device_id,
                    'sync_type': 'download',
                    'status': 'success',
                    'error_message': None,
                    'timestamp': __import__('django.utils.timezone').now(),
                }
            )
            sync_log.total_syncs = sync_log.total_syncs + 1
            sync_log.save(update_fields=['total_syncs'])
            
            elapsed_time = __import__('time').time() - start_time
            debug_print(f"[SYNC] Data retrieved in {elapsed_time:.2f} seconds")
            
            logger.info(f"Get data successful - User: {user.username}, Type: {data_type}")
            
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
            debug_print(f"[SYNC] ERROR getting data: {str(e)}")
            debug_print(f"[SYNC] Traceback:\n{error_details}")
            
            logger.error("Encrypted data retrieval failed.\n%s", error_details)
            return Response({'error': 'Failed to retrieve data'}, status=500)
