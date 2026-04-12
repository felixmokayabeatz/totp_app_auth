# twofa/views.py

from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.core.mail import EmailMultiAlternatives
from django.conf import settings
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from .models import EmailVerification
from .email_templates import get_2fa_email_template, get_password_changed_email_template, get_password_reset_email_template
import logging

logger = logging.getLogger(__name__)


@api_view(['POST'])
@permission_classes([AllowAny])
def send_2fa_code(request):
    username = request.data.get('username')
    password = request.data.get('password')
    
    if not username or not password:
        return Response({'success': False, 'error': 'Username and password required'}, status=400)
    
    user = authenticate(username=username, password=password)
    
    if not user:
        return Response({'success': False, 'error': 'Invalid username or password'}, status=401)
    
    if not user.email:
        return Response({'success': False, 'error': 'No email associated with account'}, status=400)
    
    try:
        # Delete ALL old unused codes for this user before creating a new one
        EmailVerification.objects.filter(user=user, is_used=False).delete()
        
        verification = EmailVerification.objects.create(user=user)
        
        html_content = get_2fa_email_template(user.username, verification.code)
        text_content = f"Your 2FA verification code is: {verification.code}\n\nThis code expires in 10 minutes."
        
        email = EmailMultiAlternatives(
            subject='Your 2FA Verification Code - OTP Authenticator',
            body=text_content,
            from_email=settings.EMAIL_HOST_USER,
            to=[user.email],
        )
        email.attach_alternative(html_content, "text/html")
        email.send()
        
        logger.info(f'2FA code sent to {user.email}')
        
        return Response({
            'success': True,
            'message': f'Verification code sent to {user.email}',
        })
        
    except Exception as e:
        logger.error(f'2FA error: {e}')
        return Response({'success': False, 'error': str(e)}, status=500)
    

@api_view(['POST'])
@permission_classes([AllowAny])
def verify_2fa_code(request):
    username = request.data.get('username')
    code = request.data.get('code')
    
    if not username or not code:
        return Response({'success': False, 'error': 'Username and code required'}, status=400)
    
    try:
        user = User.objects.get(username=username)
        
        # Get the LATEST unused code
        verification = EmailVerification.objects.filter(
            user=user, 
            is_used=False
        ).order_by('-created_at').first()
        
        if not verification:
            return Response({'success': False, 'error': 'No valid code found. Request a new one.'}, status=400)
        
        if verification.code != code:
            return Response({'success': False, 'error': 'Invalid code'}, status=400)
        
        if verification.is_valid():
            verification.is_used = True
            verification.save()
            return Response({'success': True, 'message': 'Code verified'})
        else:
            return Response({'success': False, 'error': 'Code expired (10 minute limit)'}, status=400)
            
    except User.DoesNotExist:
        return Response({'success': False, 'error': 'User not found'}, status=400)
    

@api_view(['POST'])
@permission_classes([AllowAny])
def send_password_reset_code(request):
    email = request.data.get('email')
    
    if not email:
        return Response({'success': False, 'error': 'Email required'}, status=400)
    
    try:
        user = User.objects.get(email=email)
        
        # Delete ALL old unused reset codes for this user
        EmailVerification.objects.filter(user=user, is_used=False).delete()
        
        verification = EmailVerification.objects.create(user=user)
        
        html_content = get_password_reset_email_template(user.username, verification.code)
        text_content = f"Your password reset code is: {verification.code}\n\nThis code expires in 10 minutes."
        
        email_msg = EmailMultiAlternatives(
            subject='Password Reset Code - BeatzLock Authenticator',
            body=text_content,
            from_email=settings.EMAIL_HOST_USER,
            to=[user.email],
        )
        email_msg.attach_alternative(html_content, "text/html")
        email_msg.send()
        
        logger.info(f'Password reset code sent to {user.email}')
        
        return Response({
            'success': True,
            'message': f'Reset code sent to {user.email}',
        })
        
    except User.DoesNotExist:
        return Response({'success': False, 'error': 'No account found with this email'}, status=404)
    except Exception as e:
        logger.error(f'Password reset error: {e}')
        return Response({'success': False, 'error': str(e)}, status=500)


@api_view(['POST'])
@permission_classes([AllowAny])
def reset_password(request):
    email = request.data.get('email')
    code = request.data.get('code')
    new_password = request.data.get('new_password')
    
    if not email or not code or not new_password:
        return Response({'success': False, 'error': 'Email, code, and new password required'}, status=400)
    
    if len(new_password) < 8:
        return Response({'success': False, 'error': 'Password must be at least 8 characters'}, status=400)
    
    try:
        user = User.objects.get(email=email)
        
        # Get the LATEST unused reset code
        verification = EmailVerification.objects.filter(
            user=user, 
            is_used=False
        ).order_by('-created_at').first()
        
        if not verification:
            return Response({'success': False, 'error': 'No valid code found. Request a new one.'}, status=400)
        
        if verification.code != code:
            return Response({'success': False, 'error': 'Invalid code'}, status=400)
        
        if not verification.is_valid():
            return Response({'success': False, 'error': 'Code expired (10 minute limit)'}, status=400)
        
        # Reset password
        user.set_password(new_password)
        user.save()
        
        # Mark code as used
        verification.is_used = True
        verification.save()
        
        # Delete any other unused codes for this user
        EmailVerification.objects.filter(user=user, is_used=False).delete()
        
        # Send password changed notification
        html_content = get_password_changed_email_template(user.username)
        text_content = f"Your password has been changed successfully. If you didn't make this change, please contact support immediately."
        
        email_msg = EmailMultiAlternatives(
            subject='Password Changed Successfully - BeatzLock Authenticator',
            body=text_content,
            from_email=settings.EMAIL_HOST_USER,
            to=[user.email],
        )
        email_msg.attach_alternative(html_content, "text/html")
        email_msg.send()
        
        logger.info(f'Password reset successful for {user.email}')
        
        return Response({'success': True, 'message': 'Password reset successfully'})
        
    except User.DoesNotExist:
        return Response({'success': False, 'error': 'User not found'}, status=404)
    except Exception as e:
        logger.error(f'Reset password error: {e}')
        return Response({'success': False, 'error': str(e)}, status=500)