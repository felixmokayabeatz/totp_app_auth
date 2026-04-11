from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.core.mail import send_mail
from django.core.mail import EmailMultiAlternatives
from django.conf import settings
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from .models import EmailVerification
from .email_templates import get_2fa_email_template, get_password_changed_email_template
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
        verification = EmailVerification.objects.create(user=user)
        
        # Create HTML email
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