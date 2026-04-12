# twofa/email_templates.py

def get_2fa_email_template(username, code):
    return f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>2FA Verification Code</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            margin: 0;
            padding: 40px 20px;
        }}
        
        .container {{
            max-width: 520px;
            margin: 0 auto;
            background: #ffffff;
            border-radius: 24px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            overflow: hidden;
            animation: slideUp 0.5s ease-out;
        }}
        
        @keyframes slideUp {{
            from {{
                opacity: 0;
                transform: translateY(30px);
            }}
            to {{
                opacity: 1;
                transform: translateY(0);
            }}
        }}
        
        .header {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 40px 30px;
            text-align: center;
        }}
        
        .logo {{
            width: 70px;
            height: 70px;
            background: rgba(255, 255, 255, 0.2);
            border-radius: 50%;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            margin-bottom: 20px;
        }}
        
        .logo svg {{
            width: 40px;
            height: 40px;
        }}
        
        .header h1 {{
            color: #ffffff;
            font-size: 28px;
            font-weight: 700;
            margin-bottom: 8px;
            letter-spacing: -0.5px;
        }}
        
        .header p {{
            color: rgba(255, 255, 255, 0.9);
            font-size: 14px;
            font-weight: 500;
        }}
        
        .content {{
            padding: 40px 30px;
        }}
        
        .greeting {{
            font-size: 18px;
            font-weight: 600;
            color: #1a1a2e;
            margin-bottom: 12px;
        }}
        
        .message {{
            font-size: 15px;
            line-height: 1.6;
            color: #4a5568;
            margin-bottom: 30px;
        }}
        
        .code-container {{
            background: linear-gradient(135deg, #f5f7ff 0%, #eef2ff 100%);
            border-radius: 16px;
            padding: 24px;
            text-align: center;
            margin: 25px 0;
            border: 1px solid rgba(102, 126, 234, 0.2);
        }}
        
        .code-label {{
            font-size: 12px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1px;
            color: #667eea;
            margin-bottom: 12px;
        }}
        
        .code {{
            font-size: 42px;
            font-weight: 700;
            letter-spacing: 8px;
            color: #667eea;
            font-family: 'Courier New', monospace;
            background: white;
            padding: 16px 20px;
            border-radius: 12px;
            display: inline-block;
            box-shadow: 0 2px 8px rgba(0, 0, 0, 0.05);
        }}
        
        .expiry {{
            font-size: 12px;
            color: #a0aec0;
            margin-top: 12px;
        }}
        
        .warning {{
            background: #fff5f5;
            border-left: 4px solid #f56565;
            padding: 16px;
            border-radius: 12px;
            margin: 25px 0;
        }}
        
        .warning-text {{
            font-size: 13px;
            color: #c53030;
            line-height: 1.5;
        }}
        
        .footer {{
            background: #f7fafc;
            padding: 30px;
            text-align: center;
            border-top: 1px solid #e2e8f0;
        }}
        
        .footer-text {{
            font-size: 12px;
            color: #a0aec0;
            line-height: 1.5;
        }}
        
        .security-badge {{
            display: inline-flex;
            align-items: center;
            gap: 8px;
            background: #e8f5e9;
            padding: 8px 16px;
            border-radius: 20px;
            font-size: 12px;
            color: #2e7d32;
            margin-bottom: 20px;
        }}
        
        @media (max-width: 600px) {{
            .container {{
                border-radius: 16px;
            }}
            .header {{
                padding: 30px 20px;
            }}
            .content {{
                padding: 30px 20px;
            }}
            .code {{
                font-size: 32px;
                letter-spacing: 6px;
            }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="logo">
                <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <path d="M12 2L2 7L12 12L22 7L12 2Z" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                    <path d="M2 17L12 22L22 17" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                    <path d="M2 12L12 17L22 12" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
            </div>
            <h1>Two-Factor Authentication</h1>
            <p>Secure your account with OTP Authenticator</p>
        </div>
        
        <div class="content">
            <div class="greeting">Hello, {username}! 👋</div>
            
            <div class="message">
                You recently requested to verify your identity. Use the verification code below to complete your action.
            </div>
            
            <div class="code-container">
                <div class="code-label">Verification Code</div>
                <div class="code">{code}</div>
                <div class="expiry">⏰ This code will expire in 10 minutes</div>
            </div>
            
            <div class="warning">
                <div class="warning-text">
                    🔒 <strong>Security Notice:</strong> If you didn't request this code, please ignore this email. 
                    Your account security is our priority.
                </div>
            </div>
            
            <div class="security-badge">
                <span>✓</span> End-to-End Encrypted
            </div>
        </div>
        
        <div class="footer">
            <div class="footer-text">
                <strong>OTP Authenticator</strong><br>
                Secure Two-Factor Authentication<br><br>
                This is an automated message, please do not reply.<br>
                &copy; 2024 OTP Authenticator. All rights reserved.
            </div>
        </div>
    </div>
</body>
</html>
    """

def get_password_changed_email_template(username):
    return f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Password Changed Successfully</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            margin: 0;
            padding: 40px 20px;
        }}
        
        .container {{
            max-width: 520px;
            margin: 0 auto;
            background: #ffffff;
            border-radius: 24px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            overflow: hidden;
            animation: slideUp 0.5s ease-out;
        }}
        
        @keyframes slideUp {{
            from {{
                opacity: 0;
                transform: translateY(30px);
            }}
            to {{
                opacity: 1;
                transform: translateY(0);
            }}
        }}
        
        .header {{
            background: linear-gradient(135deg, #10B981 0%, #059669 100%);
            padding: 40px 30px;
            text-align: center;
        }}
        
        .success-icon {{
            width: 70px;
            height: 70px;
            background: rgba(255, 255, 255, 0.2);
            border-radius: 50%;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            margin-bottom: 20px;
        }}
        
        .header h1 {{
            color: #ffffff;
            font-size: 28px;
            font-weight: 700;
            margin-bottom: 8px;
            letter-spacing: -0.5px;
        }}
        
        .header p {{
            color: rgba(255, 255, 255, 0.9);
            font-size: 14px;
            font-weight: 500;
        }}
        
        .content {{
            padding: 40px 30px;
        }}
        
        .greeting {{
            font-size: 18px;
            font-weight: 600;
            color: #1a1a2e;
            margin-bottom: 12px;
        }}
        
        .message {{
            font-size: 15px;
            line-height: 1.6;
            color: #4a5568;
            margin-bottom: 30px;
        }}
        
        .alert-container {{
            background: #e8f5e9;
            border-radius: 16px;
            padding: 24px;
            margin: 25px 0;
            border: 1px solid rgba(16, 185, 129, 0.2);
        }}
        
        .alert-title {{
            font-size: 16px;
            font-weight: 600;
            color: #065f46;
            margin-bottom: 12px;
        }}
        
        .alert-text {{
            font-size: 14px;
            color: #065f46;
            line-height: 1.5;
        }}
        
        .button {{
            display: inline-block;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            text-decoration: none;
            padding: 14px 32px;
            border-radius: 12px;
            font-weight: 600;
            font-size: 14px;
            margin: 20px 0;
            transition: transform 0.2s;
        }}
        
        .warning-box {{
            background: #fffbeb;
            border-left: 4px solid #f59e0b;
            padding: 16px;
            border-radius: 12px;
            margin: 25px 0;
        }}
        
        .warning-text {{
            font-size: 13px;
            color: #92400e;
            line-height: 1.5;
        }}
        
        .footer {{
            background: #f7fafc;
            padding: 30px;
            text-align: center;
            border-top: 1px solid #e2e8f0;
        }}
        
        .footer-text {{
            font-size: 12px;
            color: #a0aec0;
            line-height: 1.5;
        }}
        
        @media (max-width: 600px) {{
            .container {{
                border-radius: 16px;
            }}
            .header {{
                padding: 30px 20px;
            }}
            .content {{
                padding: 30px 20px;
            }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="success-icon">
                <svg width="32" height="32" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <path d="M20 6L9 17L4 12" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
            </div>
            <h1>Password Changed Successfully</h1>
            <p>Your account security has been updated</p>
        </div>
        
        <div class="content">
            <div class="greeting">Hello, {username}! 🔒</div>
            
            <div class="message">
                Your password has been successfully changed. This action was performed to enhance the security of your account.
            </div>
            
            <div class="alert-container">
                <div class="alert-title">✓ What happened?</div>
                <div class="alert-text">
                    Your account password was recently updated. If you made this change, no further action is required.
                </div>
            </div>
            
            <div class="warning-box">
                <div class="warning-text">
                    ⚠️ <strong>Didn't make this change?</strong><br>
                    If you did not change your password, please contact our support team immediately and reset your password.
                </div>
            </div>
            
            <center>
                <a href="#" class="button">Secure Your Account</a>
            </center>
        </div>
        
        <div class="footer">
            <div class="footer-text">
                <strong>OTP Authenticator</strong><br>
                Secure Two-Factor Authentication<br><br>
                This is an automated message, please do not reply.<br>
                &copy; 2024 OTP Authenticator. All rights reserved.
            </div>
        </div>
    </div>
</body>
</html>
    """


def get_password_reset_email_template(username, code):
    return f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Password Reset Code</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            margin: 0;
            padding: 40px 20px;
        }}
        
        .container {{
            max-width: 520px;
            margin: 0 auto;
            background: #ffffff;
            border-radius: 24px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            overflow: hidden;
            animation: slideUp 0.5s ease-out;
        }}
        
        @keyframes slideUp {{
            from {{
                opacity: 0;
                transform: translateY(30px);
            }}
            to {{
                opacity: 1;
                transform: translateY(0);
            }}
        }}
        
        .header {{
            background: linear-gradient(135deg, #f59e0b 0%, #d97706 100%);
            padding: 40px 30px;
            text-align: center;
        }}
        
        .logo {{
            width: 70px;
            height: 70px;
            background: rgba(255, 255, 255, 0.2);
            border-radius: 50%;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            margin-bottom: 20px;
        }}
        
        .header h1 {{
            color: #ffffff;
            font-size: 28px;
            font-weight: 700;
            margin-bottom: 8px;
            letter-spacing: -0.5px;
        }}
        
        .header p {{
            color: rgba(255, 255, 255, 0.9);
            font-size: 14px;
            font-weight: 500;
        }}
        
        .content {{
            padding: 40px 30px;
        }}
        
        .greeting {{
            font-size: 18px;
            font-weight: 600;
            color: #1a1a2e;
            margin-bottom: 12px;
        }}
        
        .message {{
            font-size: 15px;
            line-height: 1.6;
            color: #4a5568;
            margin-bottom: 30px;
        }}
        
        .code-container {{
            background: linear-gradient(135deg, #fffbeb 0%, #fef3c7 100%);
            border-radius: 16px;
            padding: 24px;
            text-align: center;
            margin: 25px 0;
            border: 1px solid rgba(245, 158, 11, 0.2);
        }}
        
        .code-label {{
            font-size: 12px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1px;
            color: #d97706;
            margin-bottom: 12px;
        }}
        
        .code {{
            font-size: 42px;
            font-weight: 700;
            letter-spacing: 8px;
            color: #d97706;
            font-family: 'Courier New', monospace;
            background: white;
            padding: 16px 20px;
            border-radius: 12px;
            display: inline-block;
            box-shadow: 0 2px 8px rgba(0, 0, 0, 0.05);
        }}
        
        .expiry {{
            font-size: 12px;
            color: #a0aec0;
            margin-top: 12px;
        }}
        
        .warning {{
            background: #fffbeb;
            border-left: 4px solid #f59e0b;
            padding: 16px;
            border-radius: 12px;
            margin: 25px 0;
        }}
        
        .warning-text {{
            font-size: 13px;
            color: #92400e;
            line-height: 1.5;
        }}
        
        .footer {{
            background: #f7fafc;
            padding: 30px;
            text-align: center;
            border-top: 1px solid #e2e8f0;
        }}
        
        .footer-text {{
            font-size: 12px;
            color: #a0aec0;
            line-height: 1.5;
        }}
        
        @media (max-width: 600px) {{
            .container {{
                border-radius: 16px;
            }}
            .header {{
                padding: 30px 20px;
            }}
            .content {{
                padding: 30px 20px;
            }}
            .code {{
                font-size: 32px;
                letter-spacing: 6px;
            }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="logo">
                <svg width="32" height="32" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <path d="M12 2L2 7L12 12L22 7L12 2Z" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                    <path d="M2 17L12 22L22 17" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                    <path d="M2 12L12 17L22 12" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
            </div>
            <h1>Password Reset Request</h1>
            <p>Secure your account with OTP Authenticator</p>
        </div>
        
        <div class="content">
            <div class="greeting">Hello, {username}! 🔐</div>
            
            <div class="message">
                We received a request to reset your password. Use the verification code below to create a new password.
            </div>
            
            <div class="code-container">
                <div class="code-label">Reset Code</div>
                <div class="code">{code}</div>
                <div class="expiry">⏰ This code will expire in 10 minutes</div>
            </div>
            
            <div class="warning">
                <div class="warning-text">
                    ⚠️ <strong>Didn't request this?</strong><br>
                    If you didn't request a password reset, please ignore this email. Your password will remain unchanged.
                </div>
            </div>
        </div>
        
        <div class="footer">
            <div class="footer-text">
                <strong>OTP Authenticator</strong><br>
                Secure Two-Factor Authentication<br><br>
                This is an automated message, please do not reply.<br>
                &copy; 2024 OTP Authenticator. All rights reserved.
            </div>
        </div>
    </div>
</body>
</html>
    """

# ============================================================
# ADD this function at the bottom of twofa/email_templates.py
# (keep all your existing get_2fa_email_template, etc.)
# ============================================================

def get_delete_otp_email_template(username, code):
    return f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Confirm Delete All Accounts</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            background: linear-gradient(135deg, #c0392b 0%, #922b21 100%);
            margin: 0;
            padding: 40px 20px;
        }}
        .container {{
            max-width: 520px;
            margin: 0 auto;
            background: #ffffff;
            border-radius: 24px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }}
        .header {{
            background: linear-gradient(135deg, #e53e3e 0%, #c53030 100%);
            padding: 40px 30px;
            text-align: center;
        }}
        .icon-wrap {{
            width: 70px;
            height: 70px;
            background: rgba(255,255,255,0.2);
            border-radius: 50%;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            margin-bottom: 20px;
        }}
        .header h1 {{
            color: #ffffff;
            font-size: 26px;
            font-weight: 700;
            margin-bottom: 8px;
        }}
        .header p {{
            color: rgba(255,255,255,0.85);
            font-size: 14px;
        }}
        .content {{ padding: 40px 30px; }}
        .greeting {{
            font-size: 18px;
            font-weight: 600;
            color: #1a1a2e;
            margin-bottom: 12px;
        }}
        .message {{
            font-size: 15px;
            line-height: 1.6;
            color: #4a5568;
            margin-bottom: 24px;
        }}
        .code-container {{
            background: linear-gradient(135deg, #fff5f5 0%, #ffe4e4 100%);
            border-radius: 16px;
            padding: 24px;
            text-align: center;
            margin: 25px 0;
            border: 1px solid rgba(229,62,62,0.25);
        }}
        .code-label {{
            font-size: 12px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1px;
            color: #c53030;
            margin-bottom: 12px;
        }}
        .code {{
            font-size: 42px;
            font-weight: 700;
            letter-spacing: 8px;
            color: #c53030;
            font-family: 'Courier New', monospace;
            background: white;
            padding: 16px 20px;
            border-radius: 12px;
            display: inline-block;
            box-shadow: 0 2px 8px rgba(0,0,0,0.08);
        }}
        .expiry {{
            font-size: 12px;
            color: #a0aec0;
            margin-top: 12px;
        }}
        .danger-box {{
            background: #fff5f5;
            border-left: 4px solid #e53e3e;
            padding: 16px;
            border-radius: 12px;
            margin: 25px 0;
        }}
        .danger-text {{
            font-size: 13px;
            color: #c53030;
            line-height: 1.6;
        }}
        .info-box {{
            background: #fffbeb;
            border-left: 4px solid #f59e0b;
            padding: 16px;
            border-radius: 12px;
            margin: 25px 0;
        }}
        .info-text {{
            font-size: 13px;
            color: #92400e;
            line-height: 1.6;
        }}
        .footer {{
            background: #f7fafc;
            padding: 30px;
            text-align: center;
            border-top: 1px solid #e2e8f0;
        }}
        .footer-text {{
            font-size: 12px;
            color: #a0aec0;
            line-height: 1.5;
        }}
        @media (max-width: 600px) {{
            .container {{ border-radius: 16px; }}
            .header {{ padding: 30px 20px; }}
            .content {{ padding: 30px 20px; }}
            .code {{ font-size: 32px; letter-spacing: 6px; }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="icon-wrap">
                <svg width="34" height="34" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <path d="M3 6H5H21" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                    <path d="M8 6V4C8 3.46957 8.21071 2.96086 8.58579 2.58579C8.96086 2.21071 9.46957 2 10 2H14C14.5304 2 15.0391 2.21071 15.4142 2.58579C15.7893 2.96086 16 3.46957 16 4V6M19 6L18.1354 19.1422C18.0584 20.1891 17.1922 21 16.1422 21H7.85786C6.80782 21 5.94156 20.1891 5.86462 19.1422L5 6H19Z" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                    <path d="M10 11V17" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                    <path d="M14 11V17" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
            </div>
            <h1>⚠️ Delete All Accounts</h1>
            <p>This action is permanent and cannot be undone</p>
        </div>

        <div class="content">
            <div class="greeting">Hello, {username}!</div>

            <div class="message">
                You requested to <strong>permanently delete all your OTP accounts</strong> from every device and the cloud.
                Use the code below to confirm this action.
            </div>

            <div class="code-container">
                <div class="code-label">Confirmation Code</div>
                <div class="code">{code}</div>
                <div class="expiry">⏰ Expires in 10 minutes</div>
            </div>

            <div class="danger-box">
                <div class="danger-text">
                    🗑️ <strong>What will be deleted:</strong><br>
                    All OTP accounts will be permanently removed from this device, all other devices, and the cloud.
                    This <strong>cannot be reversed</strong>.
                </div>
            </div>

            <div class="info-box">
                <div class="info-text">
                    🛡️ <strong>Didn't request this?</strong><br>
                    If you did not initiate this action, ignore this email. Your accounts are safe — the code must be
                    entered in the app to take effect.
                </div>
            </div>
        </div>

        <div class="footer">
            <div class="footer-text">
                <strong>BeatzLock Authenticator</strong><br>
                Secure Two-Factor Authentication<br><br>
                This is an automated message, please do not reply.<br>
                &copy; 2024 BeatzLock. All rights reserved.
            </div>
        </div>
    </div>
</body>
</html>
    """