# accounts/views.py

from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework_simplejwt.tokens import RefreshToken
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from api.models import EncryptedData
from .serializers import UserSerializer, EncryptedDataSerializer, RegisterSerializer

from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from django.contrib.auth.models import User
from .models import UserProfile
from .serializers import UserSerializer, UserProfileSerializer

class ProfileViewSet(viewsets.GenericViewSet):
    permission_classes = [IsAuthenticated]
    
    @action(detail=False, methods=['get'])
    def my_profile(self, request):
        serializer = UserSerializer(request.user)
        return Response(serializer.data)
    
    @action(detail=False, methods=['post'])
    def update_profile(self, request):
        profile, created = UserProfile.objects.get_or_create(user=request.user)
        
        if 'profile_photo' in request.FILES:
            profile.profile_photo = request.FILES['profile_photo']
        if 'bio' in request.data:
            profile.bio = request.data['bio']
        if 'encryption_public_key' in request.data:
            profile.encryption_public_key = request.data['encryption_public_key']
        if 'encryption_private_key' in request.data:
            profile.encryption_private_key = request.data['encryption_private_key']
        
        profile.save()
        serializer = UserProfileSerializer(profile)
        return Response(serializer.data)

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

class SyncViewSet(viewsets.GenericViewSet):
    permission_classes = [IsAuthenticated]
    serializer_class = EncryptedDataSerializer
    
    @action(detail=False, methods=['post'])
    def sync(self, request):
        data_type = request.data.get('data_type')
        encrypted_content = request.data.get('encrypted_content')
        version = request.data.get('version', 1)
        
        obj, created = EncryptedData.objects.update_or_create(
            user=request.user,
            data_type=data_type,
            defaults={
                'encrypted_content': encrypted_content,
                'version': version,
            }
        )
        return Response({'status': 'synced', 'version': obj.version})
    
    @action(detail=False, methods=['get'], url_path='get-data')
    def get_data(self, request):
        data_type = request.query_params.get('data_type')
        try:
            data = EncryptedData.objects.get(user=request.user, data_type=data_type)
            return Response({
                'encrypted_content': data.encrypted_content,
                'version': data.version,
                'updated_at': data.updated_at,
            })
        except EncryptedData.DoesNotExist:
            return Response({'status': 'no_data'}, status=404)