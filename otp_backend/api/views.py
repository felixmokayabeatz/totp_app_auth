# api/views.py

from rest_framework import viewsets, status
from rest_framework.decorators import action, api_view, permission_classes
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework_simplejwt.tokens import RefreshToken
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.utils import timezone
from django.core.mail import send_mail
from django.conf import settings
import json
import random
import string

from .models import EncryptedData, SyncLog, AccountTombstone, DeleteOTPCode
from .serializers import UserSerializer, EncryptedDataSerializer, RegisterSerializer
from twofa.email_templates import get_delete_otp_email_template


class AuthViewSet(viewsets.GenericViewSet):
    permission_classes = [AllowAny]
    serializer_class = RegisterSerializer
    
    @action(detail=False, methods=['post'])
    def register(self, request):
        serializer = RegisterSerializer(data=request.data)
        if serializer.is_valid():
            user = serializer.save()
            refresh = RefreshToken.for_user(user)
            return Response({
                'user': UserSerializer(user).data,
                'access': str(refresh.access_token),
                'refresh': str(refresh),
            })
        return Response(serializer.errors, status=400)
    
    @action(detail=False, methods=['post'])
    def login(self, request):
        user = authenticate(
            username=request.data.get('username'), 
            password=request.data.get('password')
        )
        if user:
            refresh = RefreshToken.for_user(user)
            return Response({
                'user': UserSerializer(user).data,
                'access': str(refresh.access_token),
                'refresh': str(refresh),
            })
        return Response({'error': 'Invalid credentials'}, status=401)
    
    @action(detail=False, methods=['post'], permission_classes=[IsAuthenticated])
    def change_password(self, request):
        user = request.user
        current_password = request.data.get('current_password')
        new_password = request.data.get('new_password')
        
        if not current_password or not new_password:
            return Response({'error': 'Current password and new password are required'}, status=400)
        
        if not user.check_password(current_password):
            return Response({'error': 'Current password is incorrect'}, status=400)
        
        if len(new_password) < 8:
            return Response({'error': 'Password must be at least 8 characters'}, status=400)
        
        user.set_password(new_password)
        user.save()
        
        return Response({'success': 'Password changed successfully'})


class SyncViewSet(viewsets.GenericViewSet):
    permission_classes = [IsAuthenticated]
    serializer_class = EncryptedDataSerializer
    
    @action(detail=False, methods=['post'])
    def sync(self, request):
        data_type = request.data.get('data_type')
        encrypted_content = request.data.get('encrypted_content')
        version = request.data.get('version', 1)
        device_id = request.data.get('device_id', 'unknown')
        deleted_accounts = request.data.get('deleted_accounts', '[]')
        
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
        
        SyncLog.objects.create(
            user=request.user,
            device_id=device_id,
            sync_type='upload',
            status='success'
        )
        
        return Response({
            'status': 'synced', 
            'version': obj.version,
            'synced_at': obj.synced_at.isoformat() if obj.synced_at else None,
            'deleted_accounts': obj.deleted_accounts,
        })
    
    @action(detail=False, methods=['get'], url_path='get-data')
    def get_data(self, request):
        data_type = request.query_params.get('data_type')
        device_id = request.query_params.get('device_id', 'unknown')
        
        try:
            data = EncryptedData.objects.get(user=request.user, data_type=data_type)
            
            SyncLog.objects.create(
                user=request.user,
                device_id=device_id,
                sync_type='download',
                status='success'
            )
            
            return Response({
                'encrypted_content': data.encrypted_content,
                'version': data.version,
                'updated_at': data.updated_at,
                'synced_at': data.synced_at.isoformat() if data.synced_at else None,
                'deleted_accounts': data.deleted_accounts if hasattr(data, 'deleted_accounts') else '[]',
            })
        except EncryptedData.DoesNotExist:
            return Response({'status': 'no_data'}, status=404)
    
    @action(detail=False, methods=['get'], url_path='tombstones')
    def tombstones(self, request):
        ids = list(
            AccountTombstone.objects
            .filter(user=request.user)
            .values_list('account_id', flat=True)
        )
        return Response({'tombstoned_ids': ids})
    
    @action(detail=False, methods=['post'], url_path='delete-account')
    def delete_account(self, request):
        account_id = request.data.get('account_id')
        device_id = request.data.get('device_id', 'unknown')
        
        if not account_id:
            return Response({'error': 'Account ID required'}, status=400)
        
        # Create tombstone record
        AccountTombstone.objects.get_or_create(user=request.user, account_id=account_id)
        
        # Also remove from EncryptedData if exists
        try:
            data = EncryptedData.objects.get(user=request.user, data_type='otp_accounts')
            deleted_accounts = json.loads(data.deleted_accounts) if data.deleted_accounts else []
            if account_id not in deleted_accounts:
                deleted_accounts.append(account_id)
                data.deleted_accounts = json.dumps(deleted_accounts)
                data.save()
        except EncryptedData.DoesNotExist:
            pass
        
        SyncLog.objects.create(
            user=request.user,
            device_id=device_id,
            sync_type='delete',
            status='success'
        )
        
        return Response({'success': True, 'account_id': account_id})
    
    @action(detail=False, methods=['post'], url_path='delete-all-accounts')
    def delete_all_accounts(self, request):
        EncryptedData.objects.filter(user=request.user, data_type='otp_accounts').delete()
        AccountTombstone.objects.get_or_create(user=request.user, account_id='__ALL__')
        return Response({'success': True})


# Separate API views for delete OTP
@api_view(['POST'])
@permission_classes([IsAuthenticated])
def send_delete_otp(request):
    try:
        code = ''.join(random.choices(string.digits, k=6))
        DeleteOTPCode.objects.create(user=request.user, code=code)
        
        # Get email template
        html_message = get_delete_otp_email_template(request.user.username, code)
        
        send_mail(
            subject='BeatzLock – Confirm Delete All Accounts',
            message=f'Your delete verification code is: {code}\n\nThis code expires in 10 minutes.',
            from_email=settings.EMAIL_HOST_USER,
            recipient_list=[request.user.email],
            html_message=html_message,
            fail_silently=False,
        )
        return Response({'success': True})
    except Exception as e:
        print(f"Send delete OTP error: {e}")
        return Response({'success': False, 'error': str(e)}, status=500)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def verify_delete_otp(request):
    code = request.data.get('code', '')
    try:
        otp_obj = DeleteOTPCode.objects.filter(
            user=request.user, 
            code=code, 
            used=False
        ).order_by('-created_at').first()
        
        if otp_obj and otp_obj.is_valid():
            otp_obj.used = True
            otp_obj.save()
            return Response({'success': True})
        return Response({'success': False, 'error': 'Invalid or expired code'}, status=400)
    except Exception as e:
        return Response({'success': False, 'error': str(e)}, status=500)
    

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def set_sync_preference(request):
    enabled = request.data.get('sync_enabled', True)
    obj, _ = EncryptedData.objects.update_or_create(
        user=request.user,
        data_type='sync_preference',
        defaults={'encrypted_content': 'true' if enabled else 'false'}
    )
    return Response({'success': True, 'sync_enabled': enabled})

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def get_sync_preference(request):
    try:
        data = EncryptedData.objects.get(user=request.user, data_type='sync_preference')
        return Response({'sync_enabled': data.encrypted_content == 'true'})
    except EncryptedData.DoesNotExist:
        return Response({'sync_enabled': True})