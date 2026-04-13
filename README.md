# BeatzLock Authenticator

This project has two parts:

- `otp_backend/` - Django backend API and admin
- `otp_auth_app/` - Flutter client app

## Project Structure

```text
totp_app/
├── otp_backend/
└── otp_auth_app/
```

## 1. Run The Django Backend

Open a terminal in the project root:

```bash
cd otp_backend
```

Install backend dependencies:

```bash
pip install -r requirements.txt
```

Run migrations:

```bash
python manage.py migrate
```

Start the backend server:

```bash
python manage.py runserver
```

Default backend URL:

```text
http://127.0.0.1:8000/
```

Admin panel:

```text
http://127.0.0.1:8000/admin/
```

## 2. Run The Flutter App

Open a second terminal in the Flutter app folder:

```bash
cd otp_auth_app
```

Install Flutter packages:

```bash
flutter pub get
```

## Windows

### Debug Run

Clean and run on Windows desktop:

```bash
flutter clean
flutter pub get
flutter run -d windows
```

If you do not need a clean rebuild:

```bash
flutter run -d windows
```

### Release Build

Build a Windows release executable:

```bash
flutter build windows --release
```

## Kali Linux

### Debug Run

Clean and run on Linux desktop:

```bash
flutter clean
flutter pub get
flutter run -d linux
```

If you do not need a clean rebuild:

```bash
flutter run -d linux
```

### Release Build

Build the Linux release app:

```bash
flutter build linux --release
```

## Android

Make sure an Android phone is connected with USB debugging enabled, or start an Android emulator first.

Check available devices:

```bash
flutter devices
```

### Debug Run

Run on Android:

```bash
flutter clean
flutter pub get
flutter run -d android
```

If you want to target a specific Android device, first copy the device id from `flutter devices`, then run:

```bash
flutter run -d <device-id>
```

### Release Build

Build a release APK:

```bash
flutter build apk --release
```

Build an Android App Bundle:

```bash
flutter build appbundle --release
```

## Quick Start

Run the backend first:

```bash
cd otp_backend
python manage.py migrate
python manage.py runserver
```

Then run the Flutter app in another terminal.

### Windows

```bash
cd otp_auth_app
flutter pub get
flutter run -d windows
```

### Kali Linux

```bash
cd otp_auth_app
flutter pub get
flutter run -d linux
```

### Android

```bash
cd otp_auth_app
flutter pub get
flutter run -d android
```

## Deployment Script

If you are deploying on the server, use:

```bash
chmod +x deploy.sh
./deploy.sh
```

Be careful when running the deployment script on a live server.
