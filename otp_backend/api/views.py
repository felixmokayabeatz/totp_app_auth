from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework_simplejwt.tokens import RefreshToken
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.utils import timezone
from .models import EncryptedData, SyncLog
from .serializers import UserSerializer, EncryptedDataSerializer, RegisterSerializer

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
        
        # Get or create the encrypted data record
        obj, created = EncryptedData.objects.update_or_create(
            user=request.user,
            data_type=data_type,
            defaults={
                'encrypted_content': encrypted_content,
                'version': version,
                'synced_at': timezone.now(),  # Update synced_at timestamp
            }
        )
        
        # Log the sync activity
        SyncLog.objects.create(
            user=request.user,
            device_id=device_id,
            sync_type='upload',
            status='success'
        )
        
        return Response({
            'status': 'synced', 
            'version': obj.version,
            'synced_at': obj.synced_at.isoformat() if obj.synced_at else None
        })
    
    @action(detail=False, methods=['get'], url_path='get-data')
    def get_data(self, request):
        data_type = request.query_params.get('data_type')
        device_id = request.query_params.get('device_id', 'unknown')
        
        try:
            data = EncryptedData.objects.get(user=request.user, data_type=data_type)
            
            # Log download activity
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
            })
        except EncryptedData.DoesNotExist:
            return Response({'status': 'no_data'}, status=404)