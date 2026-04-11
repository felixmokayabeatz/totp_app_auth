from rest_framework import serializers
from django.contrib.auth.models import User
from accounts.models import UserProfile
from api.models import EncryptedData

class UserProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = UserProfile
        fields = ['profile_photo', 'bio', 'encryption_public_key', 'updated_at']

class UserSerializer(serializers.ModelSerializer):
    profile = UserProfileSerializer(read_only=True)
    
    class Meta:
        model = User
        fields = ['id', 'username', 'email', 'profile']

class EncryptedDataSerializer(serializers.ModelSerializer):
    class Meta:
        model = EncryptedData
        fields = ['data_type', 'encrypted_content', 'version', 'updated_at']

class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True)
    
    class Meta:
        model = User
        fields = ['username', 'email', 'password']
    
    def create(self, validated_data):
        user = User.objects.create_user(**validated_data)
        # Profile will be created automatically by signal
        return user