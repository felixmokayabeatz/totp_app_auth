from rest_framework import serializers
from django.contrib.auth import get_user_model
from accounts.models import UserProfile

class UserProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = UserProfile
        fields = ['profile_photo', 'bio', 'updated_at']

class UserSerializer(serializers.ModelSerializer):
    profile = UserProfileSerializer(read_only=True)
    joined_on = serializers.DateTimeField(source='date_joined', read_only=True)
    
    class Meta:
        model = get_user_model()
        fields = ['id', 'email', 'profile', 'joined_on']
