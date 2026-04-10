# accounts/views.py - Views for user profile management and updates


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