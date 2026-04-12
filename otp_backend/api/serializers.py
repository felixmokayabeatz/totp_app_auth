# api/serializers.py

from rest_framework import serializers
from django.contrib.auth.models import User
from .models import EncryptedData

class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ['id', 'username', 'email']

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
        return user