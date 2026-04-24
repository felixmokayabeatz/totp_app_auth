from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from .serializers import UserSerializer
from .models import UserProfile
from .serializers import UserProfileSerializer
import logging
import traceback
from django.conf import settings as django_settings
from django.shortcuts import render

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
        
    

def custom_404_view(request, exception):
    return render(request, '404.html', status=404)