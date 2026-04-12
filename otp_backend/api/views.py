# api/views.py

from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework_simplejwt.tokens import RefreshToken
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.utils import timezone
import json
from .models import EncryptedData, SyncLog, AccountTombstone
from .serializers import UserSerializer, EncryptedDataSerializer, RegisterSerializer


# AT THE BOTTOM of api/views.py — add these 2 function views:

import random, string
from rest_framework.decorators import api_view, permission_classes as pc
from .models import DeleteOTPCode
from twofa.email_templates import get_delete_otp_email_template
from django.conf import settings
from django.core.mail import send_mail


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
                'deleted_accounts': data.deleted_accounts,
            })
        except EncryptedData.DoesNotExist:
            return Response({'status': 'no_data'}, status=404)
    
    @action(detail=False, methods=['post'], url_path='delete-account')
    def delete_account(self, request):
        account_id = request.data.get('account_id')
        device_id = request.data.get('device_id', 'unknown')
        
        if not account_id:
            return Response({'error': 'Account ID required'}, status=400)
        
        try:
            data = EncryptedData.objects.get(user=request.user, data_type='otp_accounts')
            deleted_accounts = json.loads(data.deleted_accounts) if data.deleted_accounts else []
            
            if account_id not in deleted_accounts:
                deleted_accounts.append(account_id)
                data.deleted_accounts = json.dumps(deleted_accounts)
                data.save()
            
            SyncLog.objects.create(
                user=request.user,
                device_id=device_id,
                sync_type='delete',
                status='success'
            )
            
            return Response({'success': True, 'deleted_accounts': deleted_accounts})
        except EncryptedData.DoesNotExist:
            return Response({'error': 'No sync data found'}, status=404)

    # INSIDE your SyncViewSet class — add these 3 methods:

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
        if not account_id:
            return Response({'error': 'account_id required'}, status=status.HTTP_400_BAD_REQUEST)
        AccountTombstone.objects.get_or_create(user=request.user, account_id=account_id)
        return Response({'success': True, 'account_id': account_id})

    @action(detail=False, methods=['post'], url_path='delete-all-accounts')
    def delete_all_accounts(self, request):
        EncryptedData.objects.filter(user=request.user, data_type='otp_accounts').delete()
        AccountTombstone.objects.get_or_create(user=request.user, account_id='__ALL__')
        return Response({'success': True})




@api_view(['POST'])
@pc([IsAuthenticated])
def send_delete_otp(request):
    code = ''.join(random.choices(string.digits, k=6))
    DeleteOTPCode.objects.create(user=request.user, code=code)
    try:
        send_mail(
            subject='BeatzLock – Confirm Delete All Accounts',
            message=f'Your delete verification code is: {code}',
            from_email=settings.DEFAULT_FROM_EMAIL,
            recipient_list=[request.user.email],
            html_message=get_delete_otp_email_template(request.user.username, code),
            fail_silently=False,
        )
        return Response({'success': True})
    except Exception as e:
        return Response({'success': False, 'error': str(e)}, status=500)


@api_view(['POST'])
@pc([IsAuthenticated])
def verify_delete_otp(request):
    code = request.data.get('code', '')
    otp_obj = (
        DeleteOTPCode.objects
        .filter(user=request.user, code=code, used=False)
        .order_by('-created_at')
        .first()
    )
    if otp_obj and otp_obj.is_valid():
        otp_obj.used = True
        otp_obj.save()
        return Response({'success': True})
    return Response({'success': False, 'error': 'Invalid or expired code'}, status=400)    