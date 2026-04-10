# twofa/views.py - Views for handling 2FA code generation and verification

from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.core.mail import send_mail
from django.conf import settings
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from .models import EmailVerification
import logging

logger = logging.getLogger(__name__)

@api_view(['POST'])
@permission_classes([AllowAny])
def send_2fa_code(request):
    username = request.data.get('username')
    password = request.data.get('password')  # ADD THIS
    
    if not username or not password:
        return Response({'success': False, 'error': 'Username and password required'}, status=400)
    
    # FIRST VERIFY PASSWORD
    user = authenticate(username=username, password=password)
    
    if not user:
        return Response({'success': False, 'error': 'Invalid username or password'}, status=401)
    
    if not user.email:
        return Response({'success': False, 'error': 'No email associated with account'}, status=400)
    
    try:
        # Create verification code
        verification = EmailVerification.objects.create(user=user)
        
        # Send real email
        try:
            send_mail(
                subject='Your 2FA Verification Code - OTP Authenticator',
                message=f'''
Hello {user.username},

Your verification code is: {verification.code}

This code expires in 10 minutes.

If you didn't request this code, please ignore this email.

Security Team
OTP Authenticator
                ''',
                from_email=settings.EMAIL_HOST_USER,
                recipient_list=[user.email],
                fail_silently=False,
            )
            
            logger.info(f'2FA code sent to {user.email}')
            
            return Response({
                'success': True, 
                'message': f'Code sent to {user.email}',
            })
            
        except Exception as email_error:
            logger.error(f'Email send failed: {email_error}')
            return Response({
                'success': False, 
                'error': f'Failed to send email: {str(email_error)}'
            }, status=500)
            
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
        verification = EmailVerification.objects.filter(
            user=user, 
            code=code, 
            is_used=False
        ).latest('created_at')
        
        if verification.is_valid():
            verification.is_used = True
            verification.save()
            return Response({'success': True, 'message': 'Code verified'})
        else:
            return Response({'success': False, 'error': 'Code expired (10 minute limit)'}, status=400)
            
    except User.DoesNotExist:
        return Response({'success': False, 'error': 'User not found'}, status=400)
    except EmailVerification.DoesNotExist:
        return Response({'success': False, 'error': 'Invalid code'}, status=400)