from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework_simplejwt.tokens import RefreshToken
from django.contrib.auth.models import User
from .models import EncryptedData
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
        from django.contrib.auth import authenticate
        user = authenticate(username=request.data['username'], 
                           password=request.data['password'])
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
    
    @action(detail=False, methods=['get'])
    def get_data(self, request):  # Changed from 'get_data' to match URL
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